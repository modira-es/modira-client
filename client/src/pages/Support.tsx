import { useEffect, useMemo, useState } from "react";
import { useLocation } from "wouter";
import { useAuth } from "@/contexts/AuthContext";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import {
  AlertCircle,
  ArrowRight,
  BriefcaseBusiness,
  Check,
  CheckCircle2,
  CircleHelp,
  Clock3,
  FileText,
  Home,
  Loader2,
  LogOut,
  Menu,
  MessageSquare,
  Plus,
  Receipt,
  Search,
  UserRound,
  Wrench,
  X,
} from "lucide-react";
import  ClientFloatingActions  from "@/components/ClientFloatingActions";

type TicketStatus = "abierto" | "en_progreso" | "cerrado";
type TicketPriority = "baja" | "normal" | "alta" | "urgente";

type SupportTicket = {
  id: string;
  user_id: string;
  company_id: string | null;
  titulo: string;
  descripcion: string;
  prioridad: TicketPriority;
  estado: TicketStatus;
  created_at: string;
  updated_at: string | null;
  fecha_cierre?: string | null;
};

const STATUS_LABELS: Record<TicketStatus, string> = {
  abierto: "Abierto",
  en_progreso: "En progreso",
  cerrado: "Cerrado",
};

const PRIORITY_LABELS: Record<TicketPriority, string> = {
  baja: "Baja",
  normal: "Normal",
  alta: "Alta",
  urgente: "Urgente",
};

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("es-ES", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(date);
}

function formatDateTime(value: string | null | undefined) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("es-ES", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

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

export default function Support() {
  const { user, loading: authLoading, signOut } = useAuth();
  const [location, setLocation] = useLocation();
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [tickets, setTickets] = useState<SupportTicket[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [searchTerm, setSearchTerm] = useState("");
  const [activeFilter, setActiveFilter] = useState<"todos" | TicketStatus>("todos");
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [selectedTicket, setSelectedTicket] = useState<SupportTicket | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [newTicket, setNewTicket] = useState({
    titulo: "",
    descripcion: "",
    prioridad: "normal" as TicketPriority,
  });

  const fetchTickets = async () => {
    if (!user) return;

    try {
      setLoading(true);
      setError(null);

      const { data, error: fetchError } = await supabase
        .from("support_tickets")
        .select(
          "id, user_id, company_id, titulo, descripcion, prioridad, estado, created_at, updated_at, fecha_cierre"
        )
        .eq("user_id", user.id)
        .order("created_at", { ascending: false });

      if (fetchError) throw fetchError;
      setTickets((data || []) as SupportTicket[]);
    } catch (err: any) {
      console.error("Error cargando soporte:", err);
      setError(err?.message || "No se han podido cargar las solicitudes de soporte.");
      setTickets([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchTickets();
  }, [user]);

  const handleLogout = async () => {
    await signOut();
    setLocation("/login");
  };

  const handleCreateTicket = async () => {
    if (!user) return;

    const titulo = newTicket.titulo.trim();
    const descripcion = newTicket.descripcion.trim();

    if (!titulo || !descripcion) {
      toast.error("Completa el asunto y la descripción.");
      return;
    }

    if (titulo.length > 200) {
      toast.error("El asunto no puede superar los 200 caracteres.");
      return;
    }

    if (descripcion.length > 5000) {
      toast.error("La descripción no puede superar los 5.000 caracteres.");
      return;
    }

    try {
      setSubmitting(true);

      const { data: profile, error: profileError } = await supabase
        .from("profiles")
        .select("company_id")
        .eq("id", user.id)
        .maybeSingle();

      if (profileError) throw profileError;

      const { error: insertError } = await supabase.from("support_tickets").insert({
        user_id: user.id,
        company_id: profile?.company_id ?? null,
        titulo,
        descripcion,
        prioridad: newTicket.prioridad,
        estado: "abierto",
      });

      if (insertError) throw insertError;

      toast.success("Solicitud enviada correctamente.");
      setNewTicket({ titulo: "", descripcion: "", prioridad: "normal" });
      setIsCreateOpen(false);
      await fetchTickets();
    } catch (err: any) {
      console.error("Error creando ticket:", err);
      toast.error(err?.message || "No se ha podido crear la solicitud.");
    } finally {
      setSubmitting(false);
    }
  };

  const counts = useMemo(
    () => ({
      total: tickets.length,
      abierto: tickets.filter((ticket) => ticket.estado === "abierto").length,
      en_progreso: tickets.filter((ticket) => ticket.estado === "en_progreso").length,
      cerrado: tickets.filter((ticket) => ticket.estado === "cerrado").length,
    }),
    [tickets]
  );

  const filteredTickets = useMemo(() => {
    const term = searchTerm.trim().toLowerCase();

    return tickets.filter((ticket) => {
      const matchesFilter = activeFilter === "todos" || ticket.estado === activeFilter;
      const matchesSearch =
        !term ||
        ticket.titulo.toLowerCase().includes(term) ||
        ticket.descripcion.toLowerCase().includes(term) ||
        ticket.id.toLowerCase().includes(term);

      return matchesFilter && matchesSearch;
    });
  }, [tickets, activeFilter, searchTerm]);

  if (authLoading || !user) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#FBFCFE]">
        <Loader2 className="h-7 w-7 animate-spin text-[#173B8F]" />
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
      <ClientAreaSidebar
        isOpen={sidebarOpen}
        onToggle={() => setSidebarOpen((value) => !value)}
        location={location}
        onNavigate={setLocation}
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
                  Soporte técnico
                </h1>
                <p className="mt-1.5 max-w-2xl text-sm text-[#718096]">
                  Gestiona tus solicitudes de soporte y consulta el estado de cada incidencia.
                </p>
              </div>

              <button
                type="button"
                onClick={() => setIsCreateOpen(true)}
                className="inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-lg bg-[#173B8F] px-4 text-[12px] font-semibold text-white shadow-[0_5px_16px_rgba(23,59,143,0.14)] transition hover:bg-[#102A66]"
              >
                <Plus className="h-4 w-4" />
                Nueva solicitud
              </button>
            </div>
          </section>

          {/* ----------------------------------------------------------
              RESUMEN — misma estructura visual que Projects.
          ---------------------------------------------------------- */}
          <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
            {[
              {
                label: "Total de solicitudes",
                value: counts.total,
                detail: counts.total === 1 ? "Solicitud registrada" : "Solicitudes registradas",
                icon: MessageSquare,
                active: counts.total > 0,
              },
              {
                label: "Solicitudes abiertas",
                value: counts.abierto,
                detail: "Pendientes de atención",
                icon: Clock3,
                active: counts.abierto > 0,
              },
              {
                label: "En progreso",
                value: counts.en_progreso,
                detail: "Siendo atendidas",
                icon: AlertCircle,
                active: counts.en_progreso > 0,
              },
              {
                label: "Solicitudes cerradas",
                value: counts.cerrado,
                detail: "Finalizadas",
                icon: Check,
                active: counts.cerrado > 0,
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
              SOLICITUDES — misma composición que la cartera de Projects.
          ---------------------------------------------------------- */}
          <section>
            <div className="mb-5 flex items-end justify-between gap-4">
              <div className="min-w-0">
                <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                  Soporte
                </p>
                <h2 className="text-xl font-semibold tracking-tight text-[#182A45] sm:text-2xl">
                  Todas tus solicitudes
                </h2>
              </div>
              <span className="shrink-0 text-[11px] text-[#8A95A5]">
                {filteredTickets.length} de {tickets.length}
              </span>
            </div>

            <div className="mb-8 border border-[#E3E8EE] bg-white p-4 sm:p-5">
              <div className="flex h-11 items-center gap-3 rounded-lg border border-[#E3E8EE] bg-[#F8FAFC] px-3.5 transition-all focus-within:border-[#173B8F] focus-within:ring-1 focus-within:ring-[#173B8F]">
                <Search
                  className="h-4 w-4 shrink-0 text-[#8F9AAA]"
                  strokeWidth={1.7}
                />
                <input
                  value={searchTerm}
                  onChange={(event) => setSearchTerm(event.target.value)}
                  placeholder="Buscar solicitud por asunto o descripción..."
                  className="h-full min-w-0 flex-1 border-0 bg-transparent p-0 text-[13px] text-[#344054] shadow-none outline-none placeholder:text-[#9AA4B2] focus:border-0 focus:outline-none focus:ring-0"
                />
              </div>

              <div className="mt-5 flex flex-wrap items-center gap-x-3 gap-y-2.5">
                <span className="mr-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                  Estado
                </span>
                {(
                  [
                    ["todos", "Todos"],
                    ["abierto", "Abiertas"],
                    ["en_progreso", "En progreso"],
                    ["cerrado", "Cerradas"],
                  ] as const
                ).map(([value, label]) => {
                  const active = activeFilter === value;
                  return (
                    <button
                      key={value}
                      type="button"
                      onClick={() => setActiveFilter(value)}
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

            {error && (
              <div className="mb-5 border border-red-200 bg-red-50 px-4 py-3 text-[12px] text-red-700">
                {error}
              </div>
            )}

            {loading ? (
              <div className="border-y border-[#E7EBF0] py-14 text-center">
                <Loader2 className="mx-auto mb-3 h-7 w-7 animate-spin text-[#173B8F]" />
                <p className="text-[12px] text-[#718096]">Cargando solicitudes...</p>
              </div>
            ) : filteredTickets.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-12 text-center">
                <MessageSquare className="mx-auto mb-4 h-7 w-7 text-[#AAB3BF]" strokeWidth={1.6} />
                <p className="text-[14px] font-semibold text-[#344054]">
                  {tickets.length ? "No hay solicitudes que coincidan" : "Todavía no tienes solicitudes"}
                </p>
                <p className="mx-auto mt-2 max-w-md text-[12px] leading-5 text-[#8792A2]">
                  {tickets.length
                    ? "Prueba con otro término de búsqueda o estado."
                    : "Puedes crear una nueva solicitud para que el equipo de Modira pueda revisarla."}
                </p>
                {tickets.length === 0 && (
                  <button
                    type="button"
                    onClick={() => setIsCreateOpen(true)}
                    className="mt-5 inline-flex items-center gap-2 rounded-lg bg-[#173B8F] px-4 py-2.5 text-[11px] font-semibold text-white hover:bg-[#102A66]"
                  >
                    <Plus className="h-3.5 w-3.5" />
                    Crear solicitud
                  </button>
                )}
              </div>
            ) : (
              <div className="space-y-5">
                {filteredTickets.map((ticket) => {
                  const statusDot =
                    ticket.estado === "abierto"
                      ? "bg-[#F59E0B]"
                      : ticket.estado === "en_progreso"
                        ? "bg-[#173B8F]"
                        : "bg-[#247A49]";

                  return (
                    <article
                      key={ticket.id}
                      className="group relative overflow-hidden rounded-[20px] border border-[#E1E7EE] bg-white transition-all duration-200 hover:-translate-y-[1px] hover:border-[#CDD6E0] hover:shadow-[0_14px_34px_rgba(24,42,69,0.07)]"
                    >
                      <div className="relative px-5 py-5 sm:px-7 sm:py-6">
                        <div className="flex items-start gap-6">
                          <div className="min-w-0 flex-1">
                            <div className="flex flex-wrap items-center gap-2.5">
                              <span
                                className={`inline-flex h-2 w-2 shrink-0 rounded-full ${statusDot}`}
                                aria-hidden="true"
                              />
                              <h3 className="min-w-0 text-[17px] font-semibold leading-tight tracking-[-0.015em] text-[#1F3048] sm:text-[18px]">
                                {ticket.titulo}
                              </h3>
                              <span className="inline-flex items-center rounded-full border border-[#DCE2E9] bg-[#F8FAFC] px-2.5 py-1 text-[9px] font-semibold uppercase tracking-[0.08em] text-[#667386]">
                                {STATUS_LABELS[ticket.estado]}
                              </span>
                              <span className="inline-flex items-center rounded-full border border-[#DCE2E9] bg-[#F8FAFC] px-2.5 py-1 text-[9px] font-semibold uppercase tracking-[0.08em] text-[#667386]">
                                {PRIORITY_LABELS[ticket.prioridad]}
                              </span>
                            </div>

                            <p className="mt-2 line-clamp-2 max-w-3xl text-[12px] leading-5 text-[#788495]">
                              {ticket.descripcion}
                            </p>

                            <div className="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1.5 text-[10px] text-[#98A2B3]">
                              <span className="inline-flex items-center gap-1.5">
                                <Clock3 className="h-3.5 w-3.5" />
                                Creado el {formatDate(ticket.created_at)}
                              </span>
                              {ticket.updated_at && ticket.updated_at !== ticket.created_at && (
                                <span>Actualizado el {formatDate(ticket.updated_at)}</span>
                              )}
                              <span className="font-mono">#{ticket.id.slice(0, 8)}</span>
                            </div>
                          </div>

                          <button
                            type="button"
                            onClick={() => setSelectedTicket(ticket)}
                            aria-label={`Ver solicitud ${ticket.titulo}`}
                            className="flex h-9 w-9 shrink-0 items-center justify-center self-end rounded-full border border-[#DCE2E9] bg-white text-[#173B8F] transition hover:border-[#C8D2DE] hover:bg-[#F4F7FB] lg:self-center"
                          >
                            <ArrowRight className="h-4 w-4" />
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

      {isCreateOpen && (
        <div className="fixed inset-0 z-[80] flex items-center justify-center overflow-y-auto bg-[#102A66]/20 px-4 py-4 backdrop-blur-[2px] sm:py-6">
          <div className="flex max-h-[calc(100dvh-2rem)] w-full max-w-[560px] flex-col overflow-hidden border border-[#E1E7EE] bg-white shadow-[0_20px_70px_rgba(24,42,69,0.16)] sm:max-h-[calc(100dvh-3rem)]">
            <div className="flex shrink-0 items-start justify-between border-b border-[#E8ECF1] px-6 py-5">
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">Soporte</p>
                <h2 className="mt-1 text-lg font-semibold tracking-tight text-[#182A45]">Nueva solicitud</h2>
                <p className="mt-1 text-[12px] leading-5 text-[#788495]">
                  Describe el problema para que el equipo pueda revisarlo.
                </p>
              </div>
              <button
                type="button"
                onClick={() => setIsCreateOpen(false)}
                className="flex h-8 w-8 items-center justify-center rounded-full text-[#7C8797] hover:bg-[#F4F6F8] hover:text-[#26344A]"
              >
                <X className="h-4 w-4" />
              </button>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-6 py-6">
              <div className="space-y-5">
                <label htmlFor="support-title" className="text-[11px] font-semibold text-[#344054]">
                  Asunto
                </label>
                <input
                  id="support-title"
                  maxLength={200}
                  value={newTicket.titulo}
                  onChange={(event) => setNewTicket((current) => ({ ...current, titulo: event.target.value }))}
                  placeholder="Ej. Problema con una factura"
                  className="mt-2 h-10 w-full rounded-lg border border-[#D7DEE7] bg-white px-3 text-[12px] text-[#26344A] outline-none transition focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
                />
                <p className="mt-1 text-right text-[9px] text-[#A0A8B4]">{newTicket.titulo.length}/200</p>
              </div>

              <div>
                <label htmlFor="support-priority" className="text-[11px] font-semibold text-[#344054]">
                  Prioridad
                </label>
                <select
                  id="support-priority"
                  value={newTicket.prioridad}
                  onChange={(event) =>
                    setNewTicket((current) => ({
                      ...current,
                      prioridad: event.target.value as TicketPriority,
                    }))
                  }
                  className="mt-2 h-10 w-full rounded-lg border border-[#D7DEE7] bg-white px-3 text-[12px] text-[#26344A] outline-none focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
                >
                  <option value="baja">Baja</option>
                  <option value="normal">Normal</option>
                  <option value="alta">Alta</option>
                  <option value="urgente">Urgente</option>
                </select>
              </div>

              <div>
                <label htmlFor="support-description" className="text-[11px] font-semibold text-[#344054]">
                  Descripción
                </label>
                <textarea
                  id="support-description"
                  maxLength={5000}
                  rows={7}
                  value={newTicket.descripcion}
                  onChange={(event) => setNewTicket((current) => ({ ...current, descripcion: event.target.value }))}
                  placeholder="Explica qué ocurre, desde cuándo sucede y cualquier detalle que pueda ayudarnos..."
                  className="mt-2 w-full resize-none rounded-lg border border-[#D7DEE7] bg-white px-3 py-3 text-[12px] leading-5 text-[#26344A] outline-none transition focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
                />
                <p className="mt-1 text-right text-[9px] text-[#A0A8B4]">{newTicket.descripcion.length}/5.000</p>
              </div>
            </div>

            <div className="flex shrink-0 justify-end gap-2 border-t border-[#E8ECF1] px-6 py-4">
              <button
                type="button"
                onClick={() => setIsCreateOpen(false)}
                className="rounded-lg border border-[#D7DEE7] bg-white px-4 py-2.5 text-[11px] font-semibold text-[#697587] hover:bg-[#F8FAFC]"
              >
                Cancelar
              </button>
              <button
                type="button"
                disabled={submitting}
                onClick={handleCreateTicket}
                className="inline-flex items-center gap-2 rounded-lg bg-[#173B8F] px-4 py-2.5 text-[11px] font-semibold text-white hover:bg-[#102A66] disabled:cursor-not-allowed disabled:opacity-60"
              >
                {submitting && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
                Enviar solicitud
              </button>
            </div>
          </div>
        </div>
      )}

      {selectedTicket && (
        <div className="fixed inset-0 z-[80] flex items-center justify-center overflow-y-auto bg-[#102A66]/20 px-4 py-4 backdrop-blur-[2px] sm:py-6">
          <div className="flex max-h-[calc(100dvh-2rem)] w-full max-w-[680px] flex-col overflow-hidden border border-[#E1E7EE] bg-white shadow-[0_20px_70px_rgba(24,42,69,0.16)] sm:max-h-[calc(100dvh-3rem)]">
            <div className="flex shrink-0 items-start justify-between border-b border-[#E8ECF1] px-6 py-5">
              <div className="min-w-0 pr-4">
                <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">Solicitud de soporte</p>
                <h2 className="mt-1 text-lg font-semibold tracking-tight text-[#182A45]">{selectedTicket.titulo}</h2>
              </div>
              <button
                type="button"
                onClick={() => setSelectedTicket(null)}
                className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-[#7C8797] hover:bg-[#F4F6F8] hover:text-[#26344A]"
              >
                <X className="h-4 w-4" />
              </button>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-6 py-6">
              <div className="space-y-6">
                <div className="flex flex-wrap gap-2">
                <span className="rounded-full border border-[#D5E0F5] bg-[#F5F8FF] px-2.5 py-1 text-[9px] font-semibold uppercase tracking-[0.08em] text-[#173B8F]">
                  {STATUS_LABELS[selectedTicket.estado]}
                </span>
                <span className="rounded-full border border-[#E2E7ED] bg-[#F8FAFC] px-2.5 py-1 text-[9px] font-semibold uppercase tracking-[0.08em] text-[#697587]">
                  Prioridad {PRIORITY_LABELS[selectedTicket.prioridad]}
                </span>
              </div>

              <div className="border-y border-[#E8ECF1] py-5">
                <p className="mb-2 text-[10px] font-semibold uppercase tracking-[0.15em] text-[#8993A2]">Descripción</p>
                <p className="whitespace-pre-wrap text-[13px] leading-6 text-[#526174]">{selectedTicket.descripcion}</p>
              </div>

              <div className="grid gap-4 sm:grid-cols-3">
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8993A2]">Creada</p>
                  <p className="mt-1 text-[12px] font-medium text-[#344054]">{formatDateTime(selectedTicket.created_at)}</p>
                </div>
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8993A2]">Última actualización</p>
                  <p className="mt-1 text-[12px] font-medium text-[#344054]">{formatDateTime(selectedTicket.updated_at)}</p>
                </div>
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8993A2]">Cierre</p>
                  <p className="mt-1 text-[12px] font-medium text-[#344054]">{formatDateTime(selectedTicket.fecha_cierre)}</p>
                </div>
              </div>

              {selectedTicket.estado === "cerrado" && (
                <div className="flex items-center gap-3 border border-[#DCEEE2] bg-[#F3FAF5] px-4 py-3 text-[11px] text-[#397654]">
                  <CheckCircle2 className="h-4 w-4 shrink-0" />
                  Esta solicitud ha sido cerrada por el equipo de soporte.
                </div>
              )}
            </div>

            </div>

            <div className="flex shrink-0 justify-end border-t border-[#E8ECF1] px-6 py-4">
              <button
                type="button"
                onClick={() => setSelectedTicket(null)}
                className="rounded-lg bg-[#173B8F] px-4 py-2.5 text-[11px] font-semibold text-white hover:bg-[#102A66]"
              >
                Cerrar
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
