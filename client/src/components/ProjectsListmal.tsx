import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import {
  ArrowLeft,
  ArrowRight,
  Bell,
  BriefcaseBusiness,
  CalendarDays,
  Check,
  ChevronLeft,
  CircleHelp,
  ClipboardList,
  Clock3,
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
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";

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

const statusConfig: Record<
  ProjectStatus,
  {
    label: string;
    dot: string;
    text: string;
    bg: string;
    ring: string;
    border: string;
  }
> = {
  Pendiente: {
    label: "Pendiente",
    dot: "bg-[#94A0B1]",
    text: "text-[#667386]",
    bg: "bg-[#F3F5F8]",
    ring: "#94A0B1",
    border: "border-[#DDE3EB]",
  },
  Activo: {
    label: "Activo",
    dot: "bg-[#5E9470]",
    text: "text-[#47785A]",
    bg: "bg-[#EFF7F1]",
    ring: "#5E9470",
    border: "border-[#CFE1D4]",
  },
  Pausado: {
    label: "Pausado",
    dot: "bg-[#B4863B]",
    text: "text-[#956F2E]",
    bg: "bg-[#FBF6EA]",
    ring: "#B4863B",
    border: "border-[#E9DDBF]",
  },
  Entregado: {
    label: "Entregado",
    dot: "bg-[#173B8F]",
    text: "text-[#173B8F]",
    bg: "bg-[#F0F4FB]",
    ring: "#173B8F",
    border: "border-[#D6DFEF]",
  },
  Completado: {
    label: "Completado",
    dot: "bg-[#173B8F]",
    text: "text-[#173B8F]",
    bg: "bg-[#F0F4FB]",
    ring: "#173B8F",
    border: "border-[#D6DFEF]",
  },
};

function cn(...classes: Array<string | false | null | undefined>) {
  return classes.filter(Boolean).join(" ");
}

function normalizeStatus(status: string | null | undefined): ProjectStatus {
  const value = String(status || "").trim().toLowerCase();

  if (value === "activo" || value === "active") return "Activo";
  if (value === "pausado" || value === "paused") return "Pausado";
  if (value === "entregado" || value === "delivered") return "Entregado";
  if (value === "completado" || value === "completed") return "Completado";
  return "Pendiente";
}

function formatDate(value: string | null | undefined, short = false) {
  if (!value) return "—";

  return new Intl.DateTimeFormat("es-ES", {
    day: "2-digit",
    month: short ? "short" : "long",
    year: "numeric",
  }).format(new Date(value));
}

function formatFileSize(bytes: number) {
  if (!bytes) return "—";
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function SectionTitle({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow: string;
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col gap-4 border-b border-[#E3E8EE] pb-5 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
          {eyebrow}
        </p>
        <h2 className="mt-1 text-xl font-semibold tracking-[-0.025em] text-[#182A45] sm:text-2xl">
          {title}
        </h2>
        {description && (
          <p className="mt-2 max-w-2xl text-sm leading-6 text-[#6E7A8D]">
            {description}
          </p>
        )}
      </div>
      {action}
    </div>
  );
}

function StatusPill({ status }: { status: ProjectStatus }) {
  const cfg = statusConfig[status];

  return (
    <span
      className={cn(
        "inline-flex items-center gap-2 px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.1em]",
        cfg.bg,
        cfg.text,
      )}
    >
      <span className={cn("h-1.5 w-1.5 rounded-full", cfg.dot)} />
      {cfg.label}
    </span>
  );
}

function ProgressRing({
  percentage,
  status,
  compact = false,
}: {
  percentage: number;
  status: ProjectStatus;
  compact?: boolean;
}) {
  const value = Math.max(0, Math.min(100, Math.round(percentage)));
  const size = compact ? 92 : 132;
  const center = size / 2;
  const radius = compact ? 34 : 49;
  const circumference = 2 * Math.PI * radius;
  const progress = (value / 100) * circumference;
  const cfg = statusConfig[status];

  return (
    <div
      className={cn(
        "relative shrink-0",
        compact ? "h-[92px] w-[92px]" : "h-[132px] w-[132px]",
      )}
    >
      <svg
        viewBox={`0 0 ${size} ${size}`}
        className="h-full w-full -rotate-90"
      >
        <circle
          cx={center}
          cy={center}
          r={radius}
          fill="none"
          stroke="#E8ECF2"
          strokeWidth={compact ? 7 : 8}
        />
        <circle
          cx={center}
          cy={center}
          r={radius}
          fill="none"
          stroke={cfg.ring}
          strokeWidth={compact ? 7 : 8}
          strokeLinecap="round"
          strokeDasharray={`${progress} ${circumference - progress}`}
        />
      </svg>

      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <span
          className={cn(
            "font-semibold tracking-[-0.04em] text-[#102A66]",
            compact ? "text-lg" : "text-2xl",
          )}
        >
          {value}%
        </span>
        <span className="text-[8px] font-medium uppercase tracking-[0.13em] text-[#7C8797]">
          progreso
        </span>
      </div>
    </div>
  );
}

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
        className={cn(
          "fixed left-0 top-0 z-50 flex h-screen flex-col border-r border-[#E3E8EE] bg-white transition-[width] duration-200 ease-out",
          isOpen ? "w-[236px]" : "w-[62px]",
        )}
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
                  className={cn(
                    "group flex w-full items-center rounded-md text-left transition-colors duration-150",
                    isOpen ? "gap-3 px-3 py-2.5" : "justify-center px-2 py-2.5",
                    active
                      ? "bg-[#173B8F] text-white"
                      : "text-[#647187] hover:bg-[#F3F5F8] hover:text-[#173B8F]",
                  )}
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
            className={cn(
              "flex w-full items-center rounded-md text-[#718096] transition-colors duration-150 hover:bg-[#F3F5F8] hover:text-[#173B8F]",
              isOpen ? "gap-3 px-3 py-2.5" : "justify-center px-2 py-2.5",
            )}
          >
            <LogOut className="h-[17px] w-[17px] shrink-0" strokeWidth={1.75} />
            {isOpen && (
              <span className="text-[12px] font-medium">Cerrar sesión</span>
            )}
          </button>
        </div>
      </aside>
    </>
  );
}

function MilestoneRail({ milestones }: { milestones: ProjectMilestone[] }) {
  if (!milestones.length) {
    return (
      <div className="border-y border-[#E8ECF2] px-5 py-8 text-sm text-[#7C8797]">
        Todavía no hay hitos definidos para este proyecto.
      </div>
    );
  }

  return (
    <div className="divide-y divide-[#E8ECF2] border-y border-[#E8ECF2]">
      {milestones.map((milestone, index) => {
        const done = milestone.estado === "completado";
        const current = milestone.estado === "en_curso";

        return (
          <div
            key={milestone.id}
            className="grid grid-cols-[34px_minmax(0,1fr)_auto] items-start gap-4 px-5 py-5 sm:grid-cols-[42px_minmax(0,1fr)_170px] sm:px-7"
          >
            <div className="relative flex justify-center">
              {index < milestones.length - 1 && (
                <span
                  className={cn(
                    "absolute left-1/2 top-8 h-[calc(100%+22px)] w-px -translate-x-1/2",
                    done ? "bg-[#9BC3A7]" : "bg-[#E0E5EC]",
                  )}
                />
              )}

              <span
                className={cn(
                  "relative z-10 flex h-8 w-8 items-center justify-center rounded-full border bg-white",
                  done
                    ? "border-[#5E9470] bg-[#EFF7F1] text-[#5E9470]"
                    : current
                      ? "border-[#173B8F] bg-[#F0F4FB] text-[#173B8F]"
                      : "border-[#D8DEE7] text-[#94A0B1]",
                )}
              >
                {done ? (
                  <Check className="h-4 w-4" strokeWidth={2} />
                ) : (
                  <span className="text-[10px] font-semibold">{index + 1}</span>
                )}
              </span>
            </div>

            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <p
                  className={cn(
                    "text-sm font-semibold",
                    done || current ? "text-[#26344A]" : "text-[#6E7A8D]",
                  )}
                >
                  {milestone.nombre}
                </p>

                {current && (
                  <span className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#173B8F]">
                    En curso
                  </span>
                )}
              </div>

              {milestone.descripcion && (
                <p className="mt-1 max-w-xl text-xs leading-5 text-[#7C8797]">
                  {milestone.descripcion}
                </p>
              )}
            </div>

            <div className="pt-0.5 text-right">
              <p className="text-[10px] uppercase tracking-[0.1em] text-[#9AA4B2]">
                Fecha prevista
              </p>
              <p className="mt-1 text-xs font-medium text-[#647187]">
                {formatDate(milestone.fecha_prevista, true)}
              </p>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function ProjectListRow({
  project,
  progress,
  milestones,
  onOpen,
}: {
  project: Project;
  progress: ProjectProgress | undefined;
  milestones: ProjectMilestone[];
  onOpen: () => void;
}) {
  const status = normalizeStatus(project.estado);
  const percentage =
    progress?.progress_percentage ??
    (milestones.length
      ? Math.round(
          (milestones.filter((m) => m.estado === "completado").length /
            milestones.length) *
            100,
        )
      : status === "Completado" || status === "Entregado"
        ? 100
        : 0);

  const nextMilestone =
    milestones.find((m) => m.estado === "en_curso") ||
    milestones.find((m) => m.estado === "pendiente");

  return (
    <article className="group border-y border-[#E3E8EE] bg-white transition-colors hover:border-[#CFD7E2]">
      <div className="grid gap-6 px-5 py-6 sm:px-7 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center lg:px-8">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <StatusPill status={status} />
            <span className="text-[10px] uppercase tracking-[0.11em] text-[#9AA4B2]">
              {milestones.length} {milestones.length === 1 ? "hito" : "hitos"}
            </span>
          </div>

          <button
            type="button"
            onClick={onOpen}
            className="mt-3 block max-w-3xl text-left text-lg font-semibold tracking-[-0.02em] text-[#182A45] transition-colors hover:text-[#173B8F] sm:text-xl"
          >
            {project.nombre}
          </button>

          <p className="mt-1.5 line-clamp-2 max-w-3xl text-sm leading-6 text-[#6E7A8D]">
            {project.descripcion || "Sin descripción disponible."}
          </p>

          <div className="mt-5 flex flex-wrap gap-x-7 gap-y-2 text-[11px] text-[#7C8797]">
            <span>
              Inicio:{" "}
              <strong className="font-medium text-[#596679]">
                {formatDate(project.fecha_inicio, true)}
              </strong>
            </span>
            <span>
              Entrega:{" "}
              <strong className="font-medium text-[#596679]">
                {formatDate(project.fecha_fin, true)}
              </strong>
            </span>
            {nextMilestone && (
              <span className="inline-flex items-center gap-1.5">
                <Clock3 className="h-3.5 w-3.5" strokeWidth={1.7} />
                {nextMilestone.nombre}
              </span>
            )}
          </div>
        </div>

        <div className="flex items-center justify-between gap-6 border-t border-[#E8ECF2] pt-5 lg:min-w-[250px] lg:justify-end lg:border-t-0 lg:pt-0">
          <ProgressRing
            percentage={percentage}
            status={status}
            compact
          />

          <button
            type="button"
            onClick={onOpen}
            className="inline-flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.08em] text-[#173B8F] transition-colors hover:text-[#102A66]"
          >
            Ver proyecto
            <ArrowRight className="h-4 w-4" strokeWidth={1.8} />
          </button>
        </div>
      </div>
    </article>
  );
}

function ProjectDetail({
  project,
  progress,
  milestones,
  updates,
  documents,
  onBack,
}: {
  project: Project;
  progress: ProjectProgress | undefined;
  milestones: ProjectMilestone[];
  updates: ProjectUpdate[];
  documents: ProjectDocument[];
  onBack: () => void;
}) {
  const status = normalizeStatus(project.estado);
  const percentage =
    progress?.progress_percentage ??
    (milestones.length
      ? Math.round(
          (milestones.filter((m) => m.estado === "completado").length /
            milestones.length) *
            100,
        )
      : status === "Completado" || status === "Entregado"
        ? 100
        : 0);

  const completed =
    progress?.completed_milestones ??
    milestones.filter((m) => m.estado === "completado").length;

  const nextMilestone =
    milestones.find((m) => m.estado === "en_curso") ||
    milestones.find((m) => m.estado === "pendiente");

  return (
    <div>
      <button
        type="button"
        onClick={onBack}
        className="mb-7 inline-flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.08em] text-[#647187] transition-colors hover:text-[#173B8F]"
      >
        <ArrowLeft className="h-4 w-4" strokeWidth={1.8} />
        Volver a proyectos
      </button>

      <header className="border-b border-[#E3E8EE] pb-8">
        <div className="flex flex-col gap-8 lg:flex-row lg:items-center lg:justify-between">
          <div className="min-w-0">
            <StatusPill status={status} />
            <h1 className="mt-3 max-w-4xl text-2xl font-semibold tracking-[-0.035em] text-[#182A45] sm:text-3xl">
              {project.nombre}
            </h1>
            <p className="mt-3 max-w-3xl text-sm leading-6 text-[#6E7A8D]">
              {project.descripcion || "Sin descripción disponible."}
            </p>
          </div>

          <ProgressRing percentage={percentage} status={status} />
        </div>
      </header>

      <section className="mt-8 grid border-y border-[#E3E8EE] bg-white sm:grid-cols-2 lg:grid-cols-4">
        <div className="border-b border-[#E8ECF2] px-5 py-5 sm:border-r lg:border-b-0">
          <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
            Progreso
          </p>
          <p className="mt-1 text-xl font-semibold tracking-[-0.025em] text-[#182A45]">
            {percentage}%
          </p>
        </div>
        <div className="border-b border-[#E8ECF2] px-5 py-5 lg:border-b-0 lg:border-r">
          <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
            Hitos
          </p>
          <p className="mt-1 text-xl font-semibold tracking-[-0.025em] text-[#182A45]">
            {completed} / {progress?.total_milestones ?? milestones.length}
          </p>
        </div>
        <div className="border-b border-[#E8ECF2] px-5 py-5 sm:border-r sm:border-b-0 lg:border-r">
          <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
            Inicio
          </p>
          <p className="mt-1 text-sm font-medium text-[#26344A]">
            {formatDate(project.fecha_inicio, true)}
          </p>
        </div>
        <div className="px-5 py-5">
          <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
            Entrega
          </p>
          <p className="mt-1 text-sm font-medium text-[#26344A]">
            {formatDate(project.fecha_fin, true)}
          </p>
        </div>
      </section>

      <section className="mt-12">
        <SectionTitle
          eyebrow="Seguimiento"
          title="Plan de trabajo"
          description={
            nextMilestone
              ? `Siguiente hito: ${nextMilestone.nombre}.`
              : "Consulta el estado de cada hito del proyecto."
          }
        />
        <div className="mt-6">
          <MilestoneRail milestones={milestones} />
        </div>
      </section>

      <section className="mt-12 grid gap-10 xl:grid-cols-[minmax(0,1.7fr)_minmax(280px,0.8fr)]">
        <div>
          <SectionTitle
            eyebrow="Actividad"
            title="Últimas novedades"
            description="Actualizaciones relacionadas con el proyecto."
          />

          <div className="mt-6 border-y border-[#E3E8EE] bg-white">
            {!updates.length ? (
              <div className="px-5 py-10 text-sm text-[#7C8797]">
                Todavía no hay novedades publicadas.
              </div>
            ) : (
              <div className="divide-y divide-[#E8ECF2]">
                {updates.slice(0, 8).map((update) => (
                  <article key={update.id} className="px-5 py-5 sm:px-7">
                    <div className="flex items-start justify-between gap-5">
                      <div className="min-w-0">
                        <h3 className="text-sm font-semibold text-[#26344A]">
                          {update.titulo}
                        </h3>
                        <p className="mt-2 whitespace-pre-line text-sm leading-6 text-[#6E7A8D]">
                          {update.contenido}
                        </p>
                      </div>
                      <span className="shrink-0 text-[10px] text-[#9AA4B2]">
                        {formatDate(update.created_at, true)}
                      </span>
                    </div>
                  </article>
                ))}
              </div>
            )}
          </div>
        </div>

        <div>
          <SectionTitle
            eyebrow="Archivos"
            title="Documentos"
            description="Documentación asociada al proyecto."
          />

          <div className="mt-6 border-y border-[#E3E8EE] bg-white">
            {!documents.length ? (
              <div className="px-5 py-10 text-sm leading-6 text-[#7C8797]">
                No hay documentos disponibles para este proyecto.
              </div>
            ) : (
              <div className="divide-y divide-[#E8ECF2]">
                {documents.slice(0, 8).map((document) => (
                  <div
                    key={document.id}
                    className="flex items-center gap-3 px-5 py-4"
                  >
                    <div className="flex h-9 w-9 shrink-0 items-center justify-center bg-[#F2F5F9] text-[#173B8F]">
                      <FileText className="h-4 w-4" strokeWidth={1.7} />
                    </div>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-xs font-semibold text-[#26344A]">
                        {document.file_name}
                      </p>
                      <p className="mt-0.5 text-[10px] text-[#9AA4B2]">
                        {formatFileSize(document.file_size)} ·{" "}
                        {formatDate(document.created_at, true)}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      </section>

      {project.change_requests_enabled && (
        <section className="mt-12 border-y border-[#D6DFEF] bg-[#F5F7FB] px-5 py-5 sm:px-7">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p className="text-xs font-semibold text-[#26344A]">
                Solicitudes de cambio habilitadas
              </p>
              <p className="mt-1 text-xs text-[#6E7A8D]">
                Puedes solicitar cambios hasta{" "}
                {formatDate(project.change_requests_deadline, true)}.
              </p>
            </div>
            <span className="text-[10px] font-semibold uppercase tracking-[0.1em] text-[#173B8F]">
              Disponible
            </span>
          </div>
        </section>
      )}
    </div>
  );
}

export default function ProjectsListactual() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [location, navigate] = useLocation();

  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [projects, setProjects] = useState<Project[]>([]);
  const [milestones, setMilestones] = useState<ProjectMilestone[]>([]);
  const [progress, setProgress] = useState<ProjectProgress[]>([]);
  const [updates, setUpdates] = useState<ProjectUpdate[]>([]);
  const [documents, setDocuments] = useState<ProjectDocument[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<"Todos" | "En curso" | "Pendientes" | "Finalizados">(
    "Todos",
  );
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);

  const loadData = useCallback(async () => {
    if (!user?.id) return;

    setLoading(true);

    try {
      const { data: projectData, error: projectError } = await supabase
        .from("projects")
        .select(
          "id, user_id, company_id, nombre, descripcion, estado, fecha_inicio, fecha_fin, change_requests_enabled, change_requests_deadline, created_at, updated_at",
        )
        .eq("user_id", user.id)
        .order("created_at", { ascending: false });

      if (projectError) throw projectError;

      const rows = (projectData || []) as Project[];
      setProjects(rows);

      if (!rows.length) {
        setMilestones([]);
        setProgress([]);
        setUpdates([]);
        setDocuments([]);
        return;
      }

      const ids = rows.map((project) => project.id);

      const [milestonesResult, progressResult, updatesResult, documentsResult] =
        await Promise.all([
          supabase
            .from("project_milestones")
            .select(
              "id, project_id, nombre, descripcion, fecha_prevista, orden, estado, completed_at, created_by, created_at, updated_at",
            )
            .in("project_id", ids)
            .order("orden", { ascending: true })
            .order("fecha_prevista", { ascending: true }),
          supabase
            .from("project_progress")
            .select(
              "project_id, total_milestones, completed_milestones, progress_percentage",
            )
            .in("project_id", ids),
          supabase
            .from("project_updates")
            .select(
              "id, project_id, titulo, contenido, created_by, created_at, updated_at",
            )
            .in("project_id", ids)
            .order("created_at", { ascending: false })
            .limit(50),
          supabase
            .from("project_documents")
            .select(
              "id, project_id, file_name, storage_path, mime_type, file_size, uploaded_by, created_at, updated_at",
            )
            .in("project_id", ids)
            .order("created_at", { ascending: false })
            .limit(50),
        ]);

      if (milestonesResult.error) {
        console.warn("[Projects] Error cargando hitos:", milestonesResult.error);
      }
      if (progressResult.error) {
        console.warn("[Projects] Error cargando progreso:", progressResult.error);
      }
      if (updatesResult.error) {
        console.warn("[Projects] Error cargando novedades:", updatesResult.error);
      }
      if (documentsResult.error) {
        console.warn("[Projects] Error cargando documentos:", documentsResult.error);
      }

      setMilestones((milestonesResult.data || []) as ProjectMilestone[]);
      setProgress((progressResult.data || []) as ProjectProgress[]);
      setUpdates((updatesResult.data || []) as ProjectUpdate[]);
      setDocuments((documentsResult.data || []) as ProjectDocument[]);
    } catch (error: any) {
      console.error("[Projects] Error:", error);
      toast.error(error?.message || "No se han podido cargar los proyectos.");
    } finally {
      setLoading(false);
    }
  }, [user?.id]);

  useEffect(() => {
    if (!authLoading && user?.id) {
      void loadData();
    }
  }, [authLoading, user?.id, loadData]);

  const projectProgress = useMemo(
    () => new Map(progress.map((item) => [item.project_id, item])),
    [progress],
  );

  const projectMilestones = useMemo(() => {
    const map = new Map<string, ProjectMilestone[]>();

    milestones.forEach((milestone) => {
      const current = map.get(milestone.project_id) || [];
      current.push(milestone);
      map.set(milestone.project_id, current);
    });

    return map;
  }, [milestones]);

  const projectUpdates = useMemo(() => {
    const map = new Map<string, ProjectUpdate[]>();

    updates.forEach((update) => {
      const current = map.get(update.project_id) || [];
      current.push(update);
      map.set(update.project_id, current);
    });

    return map;
  }, [updates]);

  const projectDocuments = useMemo(() => {
    const map = new Map<string, ProjectDocument[]>();

    documents.forEach((document) => {
      const current = map.get(document.project_id) || [];
      current.push(document);
      map.set(document.project_id, current);
    });

    return map;
  }, [documents]);

  const filteredProjects = useMemo(() => {
    const term = search.trim().toLowerCase();

    return projects.filter((project) => {
      const status = normalizeStatus(project.estado);

      const matchesSearch =
        !term ||
        project.nombre.toLowerCase().includes(term) ||
        String(project.descripcion || "").toLowerCase().includes(term);

      const matchesFilter =
        filter === "Todos" ||
        (filter === "En curso" && (status === "Activo" || status === "Pausado")) ||
        (filter === "Pendientes" && status === "Pendiente") ||
        (filter === "Finalizados" &&
          (status === "Completado" || status === "Entregado"));

      return matchesSearch && matchesFilter;
    });
  }, [projects, search, filter]);

  const selectedProject = projects.find((project) => project.id === selectedProjectId);

  const selectedMilestones = selectedProject
    ? projectMilestones.get(selectedProject.id) || []
    : [];

  const selectedProgress = selectedProject
    ? projectProgress.get(selectedProject.id)
    : undefined;

  const selectedUpdates = selectedProject
    ? projectUpdates.get(selectedProject.id) || []
    : [];

  const selectedDocuments = selectedProject
    ? projectDocuments.get(selectedProject.id) || []
    : [];

  const activeCount = projects.filter((project) => {
    const status = normalizeStatus(project.estado);
    return status === "Activo" || status === "Pausado";
  }).length;

  const pendingCount = projects.filter(
    (project) => normalizeStatus(project.estado) === "Pendiente",
  ).length;

  const finishedCount = projects.filter((project) => {
    const status = normalizeStatus(project.estado);
    return status === "Completado" || status === "Entregado";
  }).length;

  const navigateFromSidebar = (path: string) => {
    if (path.startsWith("#")) {
      const target = document.getElementById(path.slice(1));
      target?.scrollIntoView({ behavior: "smooth" });
      return;
    }

    navigate(path);
  };

  const openProject = (project: Project) => {
    setSelectedProjectId(project.id);
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const closeProject = () => {
    setSelectedProjectId(null);
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  if (authLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#FBFCFE]">
        <Loader2 className="h-5 w-5 animate-spin text-[#173B8F]" />
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
      <ClientAreaSidebar
        isOpen={sidebarOpen}
        onToggle={() => setSidebarOpen((value) => !value)}
        location={location}
        onNavigate={navigateFromSidebar}
        onLogout={() => signOut?.()}
      />

      <div
        className={cn(
          "min-h-screen transition-[margin] duration-200",
          sidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]",
        )}
      >
        <div className="fixed right-5 top-5 z-30 flex gap-2">
          <button
            type="button"
            aria-label="Calendario"
            className="flex h-10 w-10 items-center justify-center rounded-full border border-[#E3E8EE] bg-white text-[#647187] shadow-sm transition hover:border-[#173B8F] hover:text-[#173B8F]"
          >
            <CalendarDays className="h-[17px] w-[17px]" strokeWidth={1.8} />
          </button>
          <button
            type="button"
            aria-label="Notificaciones"
            className="relative flex h-10 w-10 items-center justify-center rounded-full border border-[#E3E8EE] bg-white text-[#647187] shadow-sm transition hover:border-[#173B8F] hover:text-[#173B8F]"
          >
            <Bell className="h-[17px] w-[17px]" strokeWidth={1.8} />
          </button>
        </div>

        <main className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
          {selectedProject ? (
            <ProjectDetail
              project={selectedProject}
              progress={selectedProgress}
              milestones={selectedMilestones}
              updates={selectedUpdates}
              documents={selectedDocuments}
              onBack={closeProject}
            />
          ) : (
            <>
              <header className="border-b border-[#E3E8EE] pb-8">
                <div className="flex flex-col gap-7 lg:flex-row lg:items-end lg:justify-between">
                  <div>
                    <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                      Área de Cliente
                    </p>
                    <h1 className="mt-1 text-2xl font-semibold tracking-[-0.035em] text-[#182A45] sm:text-3xl">
                      Mis proyectos
                    </h1>
                    <p className="mt-2 max-w-2xl text-sm leading-6 text-[#6E7A8D]">
                      Sigue el estado de tus proyectos, consulta su progreso y
                      accede a toda la información de cada trabajo.
                    </p>
                  </div>

                  <div className="grid grid-cols-3 border-y border-[#E3E8EE] bg-white sm:min-w-[390px]">
                    <div className="px-4 py-3">
                      <p className="text-[9px] font-semibold uppercase tracking-[0.13em] text-[#8A95A5]">
                        Total
                      </p>
                      <p className="mt-0.5 text-lg font-semibold text-[#182A45]">
                        {projects.length}
                      </p>
                    </div>
                    <div className="border-l border-[#E8ECF2] px-4 py-3">
                      <p className="text-[9px] font-semibold uppercase tracking-[0.13em] text-[#8A95A5]">
                        En curso
                      </p>
                      <p className="mt-0.5 text-lg font-semibold text-[#47785A]">
                        {activeCount}
                      </p>
                    </div>
                    <div className="border-l border-[#E8ECF2] px-4 py-3">
                      <p className="text-[9px] font-semibold uppercase tracking-[0.13em] text-[#8A95A5]">
                        Finalizados
                      </p>
                      <p className="mt-0.5 text-lg font-semibold text-[#173B8F]">
                        {finishedCount}
                      </p>
                    </div>
                  </div>
                </div>
              </header>

              <section className="mt-10">
                <div className="flex flex-col gap-4 border-b border-[#E3E8EE] pb-4 lg:flex-row lg:items-center lg:justify-between">
                  <div className="flex flex-wrap gap-1">
                    {(["Todos", "En curso", "Pendientes", "Finalizados"] as const).map(
                      (item) => (
                        <button
                          key={item}
                          type="button"
                          onClick={() => setFilter(item)}
                          className={cn(
                            "px-3 py-2 text-[11px] font-semibold transition-colors",
                            filter === item
                              ? "bg-[#173B8F] text-white"
                              : "text-[#647187] hover:bg-[#F3F5F8] hover:text-[#173B8F]",
                          )}
                        >
                          {item}
                          {item === "En curso" && (
                            <span className="ml-1.5 opacity-70">{activeCount}</span>
                          )}
                          {item === "Pendientes" && (
                            <span className="ml-1.5 opacity-70">{pendingCount}</span>
                          )}
                        </button>
                      ),
                    )}
                  </div>

                  <div className="relative w-full lg:w-[260px]">
                    <Search
                      className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#9AA4B2]"
                      strokeWidth={1.7}
                    />
                    <input
                      value={search}
                      onChange={(event) => setSearch(event.target.value)}
                      placeholder="Buscar proyecto..."
                      className="h-10 w-full border border-[#DDE3EB] bg-white pl-9 pr-3 text-xs text-[#26344A] outline-none transition placeholder:text-[#A0A9B7] focus:border-[#173B8F]"
                    />
                  </div>
                </div>
              </section>

              <section className="mt-8">
                {loading ? (
                  <div className="flex min-h-[260px] items-center justify-center border-y border-[#E3E8EE] bg-white">
                    <div className="flex items-center gap-2 text-sm text-[#7C8797]">
                      <Loader2 className="h-4 w-4 animate-spin text-[#173B8F]" />
                      Cargando proyectos...
                    </div>
                  </div>
                ) : filteredProjects.length === 0 ? (
                  <div className="border-y border-[#E3E8EE] bg-white px-6 py-16 text-center">
                    <BriefcaseBusiness
                      className="mx-auto h-8 w-8 text-[#A3ACB9]"
                      strokeWidth={1.4}
                    />
                    <p className="mt-4 text-sm font-semibold text-[#26344A]">
                      {search
                        ? "No se han encontrado proyectos"
                        : "No hay proyectos en esta categoría"}
                    </p>
                    <p className="mx-auto mt-1 max-w-md text-sm leading-6 text-[#7C8797]">
                      {search
                        ? "Prueba con otro término de búsqueda."
                        : "Cuando haya proyectos disponibles para tu cuenta aparecerán aquí."}
                    </p>
                  </div>
                ) : (
                  <div className="space-y-3">
                    {filteredProjects.map((project) => (
                      <ProjectListRow
                        key={project.id}
                        project={project}
                        progress={projectProgress.get(project.id)}
                        milestones={projectMilestones.get(project.id) || []}
                        onOpen={() => openProject(project)}
                      />
                    ))}
                  </div>
                )}
              </section>

              <section className="mt-14">
                <SectionTitle
                  eyebrow="Resumen"
                  title="Tu actividad de proyectos"
                  description="Una vista rápida del estado actual de tu cartera de proyectos."
                />

                <div className="mt-6 grid border-y border-[#E3E8EE] bg-white sm:grid-cols-3">
                  <div className="px-5 py-6 sm:px-7">
                    <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
                      En curso
                    </p>
                    <p className="mt-1 text-2xl font-semibold tracking-[-0.035em] text-[#47785A]">
                      {activeCount}
                    </p>
                    <p className="mt-1 text-xs text-[#7C8797]">
                      Activos o pausados
                    </p>
                  </div>
                  <div className="border-t border-[#E8ECF2] px-5 py-6 sm:border-l sm:border-t-0 sm:px-7">
                    <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
                      Pendientes
                    </p>
                    <p className="mt-1 text-2xl font-semibold tracking-[-0.035em] text-[#956F2E]">
                      {pendingCount}
                    </p>
                    <p className="mt-1 text-xs text-[#7C8797]">
                      A la espera de inicio
                    </p>
                  </div>
                  <div className="border-t border-[#E8ECF2] px-5 py-6 sm:border-l sm:border-t-0 sm:px-7">
                    <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
                      Finalizados
                    </p>
                    <p className="mt-1 text-2xl font-semibold tracking-[-0.035em] text-[#173B8F]">
                      {finishedCount}
                    </p>
                    <p className="mt-1 text-xs text-[#7C8797]">
                      Entregados o completados
                    </p>
                  </div>
                </div>
              </section>

              <section className="mt-14 border-t border-[#E3E8EE] pt-7">
                <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                      Soporte
                    </p>
                    <p className="mt-1 text-xs text-[#8A95A5]">
                      ¿Necesitas ayuda con alguno de tus proyectos?
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => navigate("/area-cliente/soporte")}
                    className="inline-flex items-center gap-2 text-xs font-semibold text-[#173B8F] transition hover:text-[#102A66]"
                  >
                    Contactar con soporte
                    <ArrowRight className="h-4 w-4" strokeWidth={1.8} />
                  </button>
                </div>
              </section>
            </>
          )}
        </main>

        <footer className="border-t border-[#E3E8EE] bg-white">
          <div className="mx-auto flex max-w-[1380px] flex-col gap-2 px-5 py-6 text-[11px] text-[#8A95A5] sm:flex-row sm:items-center sm:justify-between sm:px-8 lg:px-12">
            <span>© {new Date().getFullYear()} Modira</span>
            <span>Área de Cliente</span>
          </div>
        </footer>
      </div>
    </div>
  );
}
