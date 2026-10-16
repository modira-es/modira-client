import { useEffect, useMemo, useState } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { Bell, CalendarDays, ChevronLeft, ChevronRight } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

interface Project {
  id: string;
  nombre: string;
  fecha_fin: string | null;
  change_requests_enabled: boolean;
  change_requests_deadline: string | null;
}

type MilestoneStatus = "pendiente" | "en_curso" | "completado";

interface ProjectMilestone {
  id: string;
  project_id: string;
  nombre: string;
  fecha_prevista: string;
  orden: number;
  estado: MilestoneStatus;
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

interface Invoice {
  id: string;
  project_id: string | null;
  company_id: string | null;
  numero_factura: string;
  fecha_vencimiento: string | null;
}

interface Quotation {
  id: string;
  project_id?: string | null;
  numero_presupuesto?: string | null;
  titulo?: string | null;
  fecha_validez?: string | null;
}

interface CalendarEvent {
  id: string;
  date: Date;
  dateKey: string;
  title: string;
  subtitle: string;
  type: "milestone" | "project" | "invoice" | "quotation" | "change";
  projectId?: string;
}

const calendarTypeMeta = {
  milestone: {
    label: "Hito",
    dot: "bg-[#173B8F]",
    border: "border-[#173B8F]",
    text: "text-[#173B8F]",
    bg: "bg-[#F3F6FC]",
  },
  project: {
    label: "Proyecto",
    dot: "bg-[#5E9470]",
    border: "border-[#5E9470]",
    text: "text-[#5E9470]",
    bg: "bg-[#F1F7F2]",
  },
  invoice: {
    label: "Factura",
    dot: "bg-[#9E5555]",
    border: "border-[#9E5555]",
    text: "text-[#9E5555]",
    bg: "bg-[#FBF2F2]",
  },
  quotation: {
    label: "Presupuesto",
    dot: "bg-[#6B5A8E]",
    border: "border-[#6B5A8E]",
    text: "text-[#6B5A8E]",
    bg: "bg-[#F5F2FA]",
  },
  change: {
    label: "Cambios",
    dot: "bg-[#B4863B]",
    border: "border-[#B4863B]",
    text: "text-[#9A7130]",
    bg: "bg-[#FBF7ED]",
  },
} as const;

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

const formatDate = (value?: string | null) =>
  value ? longDate.format(new Date(value)) : "Sin fecha";

const formatCompactDate = (value?: string | null) =>
  value ? compactDate.format(new Date(value)) : "Sin fecha";

export default function ClientFloatingActions() {
  const { user, loading: authLoading } = useAuth();
  const [, setLocation] = useLocation();

  const [projects, setProjects] = useState<Project[]>([]);
  const [milestones, setMilestones] = useState<ProjectMilestone[]>([]);
  const [notifications, setNotifications] = useState<ClientNotification[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [quotations, setQuotations] = useState<Quotation[]>([]);

  const [isNotificationsOpen, setIsNotificationsOpen] = useState(false);
  const [isCalendarOpen, setIsCalendarOpen] = useState(false);

  const [calendarMonth, setCalendarMonth] = useState(() => {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), 1);
  });
  const [selectedCalendarDate, setSelectedCalendarDate] = useState<string | null>(null);

  useEffect(() => {
    if (authLoading || !user) {
      if (!user && !authLoading) {
        setProjects([]);
        setMilestones([]);
        setNotifications([]);
        setInvoices([]);
        setQuotations([]);
      }
      return;
    }

    let cancelled = false;

    const fetchFloatingActionsData = async () => {
      try {
        const { data: profileData, error: profileError } = await supabase
          .from("profiles")
          .select("company_id")
          .eq("id", user.id)
          .maybeSingle();

        if (profileError) throw profileError;

        if (cancelled) return;

        const companyId = (profileData as { company_id?: string | null } | null)?.company_id || null;

        const [projectsResult, notificationsResult, invoicesResult, quotationsResult] = await Promise.all([
          supabase
            .from("projects")
            .select(
              "id, nombre, fecha_fin, change_requests_enabled, change_requests_deadline"
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
          companyId
            ? supabase
                .from("invoices")
                .select("id, project_id, company_id, numero_factura, fecha_vencimiento")
                .eq("company_id", companyId)
                .order("created_at", { ascending: false })
            : supabase
                .from("invoices")
                .select("id, project_id, company_id, numero_factura, fecha_vencimiento")
                .eq("user_id", user.id)
                .order("created_at", { ascending: false }),
          companyId
            ? supabase
                .from("quotations")
                .select("id, project_id, numero_presupuesto, titulo, fecha_validez")
                .eq("company_id", companyId)
                .order("created_at", { ascending: false })
            : Promise.resolve({ data: [] as Quotation[], error: null }),
        ]);

        if (cancelled) return;

        if (projectsResult.error) {
          console.error("[ClientFloatingActions] Error cargando proyectos:", projectsResult.error);
          setProjects([]);
          setMilestones([]);
        } else {
          const resolvedProjects = (projectsResult.data || []) as Project[];
          setProjects(resolvedProjects);

          const projectIds = resolvedProjects.map((project) => project.id);

          if (!projectIds.length) {
            setMilestones([]);
          } else {
            const { data: milestonesData, error: milestonesError } = await supabase
              .from("project_milestones")
              .select("id, project_id, nombre, fecha_prevista, orden, estado")
              .in("project_id", projectIds)
              .order("orden", { ascending: true })
              .order("fecha_prevista", { ascending: true });

            if (cancelled) return;

            if (milestonesError) {
              console.error(
                "[ClientFloatingActions] Error cargando hitos:",
                milestonesError
              );
              setMilestones([]);
            } else {
              setMilestones((milestonesData || []) as ProjectMilestone[]);
            }
          }
        }

        if (notificationsResult.error) {
          console.error(
            "[ClientFloatingActions] Error cargando notificaciones:",
            notificationsResult.error
          );
          setNotifications([]);
        } else {
          setNotifications((notificationsResult.data || []) as ClientNotification[]);
        }

        if (invoicesResult.error) {
          console.error("[ClientFloatingActions] Error cargando facturas:", invoicesResult.error);
          setInvoices([]);
        } else {
          setInvoices((invoicesResult.data || []) as Invoice[]);
        }

        if (quotationsResult.error) {
          console.error(
            "[ClientFloatingActions] Error cargando presupuestos:",
            quotationsResult.error
          );
          setQuotations([]);
        } else {
          setQuotations((quotationsResult.data || []) as Quotation[]);
        }
      } catch (error) {
        if (cancelled) return;
        console.error(
          "[ClientFloatingActions] Error cargando datos de calendario/notificaciones:",
          error
        );
        setProjects([]);
        setMilestones([]);
        setNotifications([]);
        setInvoices([]);
        setQuotations([]);
      }
    };

    void fetchFloatingActionsData();

    return () => {
      cancelled = true;
    };
  }, [authLoading, user]);

  const projectById = useMemo(
    () => new Map(projects.map((project) => [project.id, project])),
    [projects]
  );

  const unreadNotifications = useMemo(
    () => notifications.filter((item) => !item.read_at),
    [notifications]
  );

  const calendarEvents = useMemo<CalendarEvent[]>(() => {
    const events: CalendarEvent[] = [];

    const addEvent = (
      id: string,
      dateValue: string | null | undefined,
      title: string,
      subtitle: string,
      type: CalendarEvent["type"],
      projectId?: string
    ) => {
      if (!dateValue) return;
      const date = new Date(dateValue);
      if (Number.isNaN(date.getTime())) return;

      events.push({
        id,
        date,
        dateKey: `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`,
        title,
        subtitle,
        type,
        projectId,
      });
    };

    milestones
      .filter((milestone) => projectById.has(milestone.project_id))
      .forEach((milestone) =>
        addEvent(
          `milestone-${milestone.id}`,
          milestone.fecha_prevista,
          milestone.nombre,
          projectById.get(milestone.project_id)?.nombre || "Proyecto",
          "milestone",
          milestone.project_id
        )
      );

    projects.forEach((project) => {
      addEvent(
        `project-end-${project.id}`,
        project.fecha_fin,
        "Finalización del proyecto",
        project.nombre,
        "project",
        project.id
      );

      if (project.change_requests_enabled) {
        addEvent(
          `change-deadline-${project.id}`,
          project.change_requests_deadline,
          "Fecha límite para solicitar cambios",
          project.nombre,
          "change",
          project.id
        );
      }
    });

    invoices
      .filter((invoice) => Boolean(invoice.fecha_vencimiento))
      .forEach((invoice) =>
        addEvent(
          `invoice-${invoice.id}`,
          invoice.fecha_vencimiento,
          `Vencimiento · ${invoice.numero_factura}`,
          invoice.project_id
            ? projectById.get(invoice.project_id)?.nombre || "Proyecto"
            : "Facturación",
          "invoice",
          invoice.project_id || undefined
        )
      );

    quotations
      .filter((quotation) => Boolean(quotation.fecha_validez))
      .forEach((quotation) =>
        addEvent(
          `quotation-${quotation.id}`,
          quotation.fecha_validez,
          `Validez · ${quotation.numero_presupuesto || quotation.titulo || "Presupuesto"}`,
          quotation.project_id
            ? projectById.get(quotation.project_id)?.nombre || "Proyecto"
            : "Presupuestos",
          "quotation",
          quotation.project_id || undefined
        )
      );

    return events.sort((a, b) => a.date.getTime() - b.date.getTime());
  }, [milestones, projects, invoices, quotations, projectById]);

  const calendarGrid = useMemo(() => {
    const year = calendarMonth.getFullYear();
    const month = calendarMonth.getMonth();
    const firstDay = new Date(year, month, 1);
    const daysInMonth = new Date(year, month + 1, 0).getDate();
    const mondayOffset = (firstDay.getDay() + 6) % 7;
    const cells: Array<number | null> = Array.from(
      { length: mondayOffset },
      () => null
    );

    for (let day = 1; day <= daysInMonth; day += 1) {
      cells.push(day);
    }

    while (cells.length % 7 !== 0) {
      cells.push(null);
    }

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

  const handleOpenCalendar = () => {
    const future = calendarEvents.find(
      (event) => event.date.getTime() >= Date.now()
    );

    if (future) {
      setCalendarMonth(
        new Date(future.date.getFullYear(), future.date.getMonth(), 1)
      );
      setSelectedCalendarDate(future.dateKey);
    } else {
      const now = new Date();
      setCalendarMonth(new Date(now.getFullYear(), now.getMonth(), 1));
      setSelectedCalendarDate(null);
    }

    setIsCalendarOpen(true);
  };

  const handleMarkNotificationRead = async (
    notification: ClientNotification
  ) => {
    try {
      if (!notification.read_at) {
        const { data, error: markError } = await supabase.rpc(
          "mark_notification_read",
          {
            p_notification_id: notification.id,
          }
        );

        if (markError) throw markError;

        const updated = data as ClientNotification;
        setNotifications((current) =>
          current.map((item) =>
            item.id === updated.id ? updated : item
          )
        );
      }

      const type = (notification.tipo || "").trim().toLowerCase();

      if (type === "quotation") {
        setIsNotificationsOpen(false);
        setLocation("/area-cliente/presupuestos");
      } else if (type === "invoice") {
        setIsNotificationsOpen(false);
        setLocation("/area-cliente/facturacion");
      } else if (type === "document_available") {
        setIsNotificationsOpen(false);
        setLocation("/area-cliente/documentos");
      } else if (
        notification.project_id ||
        [
          "milestone_completed",
          "project_update",
          "project_change_request",
          "information_requested",
        ].includes(type)
      ) {
        setIsNotificationsOpen(false);
        setLocation("/area-cliente/proyectos");
      }
    } catch (error) {
      console.error(
        "[ClientFloatingActions] Error gestionando notificación:",
        error
      );
      toast.error("No se ha podido gestionar la notificación.");
    }
  };

  const handleMarkAllNotificationsRead = async () => {
    if (!unreadNotifications.length) return;

    try {
      const { error: markError } = await supabase.rpc(
        "mark_all_notifications_read"
      );

      if (markError) throw markError;

      const now = new Date().toISOString();
      setNotifications((current) =>
        current.map((item) => ({
          ...item,
          read_at: item.read_at || now,
        }))
      );
    } catch (error) {
      console.error(
        "[ClientFloatingActions] Error marcando notificaciones:",
        error
      );
      toast.error("No se han podido marcar las notificaciones.");
    }
  };

  return (
    <div className="fixed right-5 top-5 z-40 flex items-center gap-2 sm:right-7">
      <Dialog open={isCalendarOpen} onOpenChange={setIsCalendarOpen}>
        <DialogTrigger asChild>
          <button
            type="button"
            onClick={handleOpenCalendar}
            aria-label="Abrir calendario"
            title="Calendario"
            className="relative flex h-10 w-10 items-center justify-center rounded-full border border-[#D7DEE7] bg-white text-[#667386] transition-all duration-200 hover:border-[#C7D0DB] hover:bg-[#F3F5F8] hover:text-[#445166]"
          >
            <CalendarDays className="h-[17px] w-[17px]" strokeWidth={1.8} />
          </button>
        </DialogTrigger>

        <DialogContent className="sm:max-w-3xl">
          <DialogHeader>
            <DialogTitle className="text-[#182A45]">Calendario</DialogTitle>
            <DialogDescription>
              Todas las fechas importantes de tus proyectos, presupuestos y facturas. Cada tipo de fecha tiene su propio color.
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
                      new Date(
                        calendarMonth.getFullYear(),
                        calendarMonth.getMonth() - 1,
                        1
                      )
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
                      new Date(
                        calendarMonth.getFullYear(),
                        calendarMonth.getMonth() + 1,
                        1
                      )
                    )
                  }
                  aria-label="Mes siguiente"
                >
                  <ChevronRight className="h-4 w-4" />
                </Button>
              </div>

              <div className="grid grid-cols-7 text-center text-[10px] font-semibold uppercase tracking-wider text-[#98A1AE]">
                {["L", "M", "X", "J", "V", "S", "D"].map((day) => (
                  <span key={day} className="py-2">
                    {day}
                  </span>
                ))}
              </div>

              <div className="grid grid-cols-7 gap-1">
                {calendarGrid.map((day, index) => {
                  if (!day) {
                    return (
                      <div
                        key={`empty-${index}`}
                        className="h-10"
                      />
                    );
                  }

                  const dateKey = `${calendarMonth.getFullYear()}-${String(
                    calendarMonth.getMonth() + 1
                  ).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
                  const dayEvents = calendarEvents.filter(
                    (event) => event.dateKey === dateKey
                  );
                  const selected = selectedCalendarDate === dateKey;

                  return (
                    <button
                      key={dateKey}
                      type="button"
                      onClick={() => setSelectedCalendarDate(dateKey)}
                      className={[
                        "relative flex h-10 items-center justify-center rounded-md text-xs transition",
                        selected
                          ? "bg-[#173B8F] font-semibold text-white"
                          : "text-[#445166] hover:bg-[#F2F5F9]",
                      ].join(" ")}
                    >
                      {day}

                      {dayEvents.length > 0 && (
                        <span className="absolute bottom-1 flex max-w-[24px] items-center justify-center gap-0.5">
                          {dayEvents.slice(0, 4).map((event) => (
                            <span
                              key={`${dateKey}-${event.id}`}
                              className={`h-1 w-1 rounded-full ${
                                selected
                                  ? "bg-white"
                                  : calendarTypeMeta[event.type].dot
                              }`}
                            />
                          ))}
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>

              <div className="mt-5 flex flex-wrap gap-x-4 gap-y-2 border-t border-[#EEF1F5] pt-4">
                {Object.entries(calendarTypeMeta).map(([type, meta]) => (
                  <div key={type} className="flex items-center gap-1.5">
                    <span
                      className={`h-1.5 w-1.5 rounded-full ${meta.dot}`}
                    />
                    <span className="text-[10px] text-[#7C8797]">
                      {meta.label}
                    </span>
                  </div>
                ))}
              </div>
            </div>

            <div className="min-h-36">
              <p className="mb-4 text-[10px] font-semibold uppercase tracking-[0.16em] text-[#8792A3]">
                {selectedCalendarDate
                  ? formatDate(`${selectedCalendarDate}T12:00:00`)
                  : "Selecciona una fecha"}
              </p>

              {selectedDayEvents.length === 0 ? (
                <p className="text-sm leading-6 text-[#7C8797]">
                  No hay fechas importantes previstas para esta fecha.
                </p>
              ) : (
                <div className="space-y-4">
                  {selectedDayEvents.map((event) => {
                    const meta = calendarTypeMeta[event.type];

                    return (
                      <div
                        key={event.id}
                        className={`border-l-2 pl-4 ${meta.border}`}
                      >
                        <div className="flex flex-wrap items-center gap-2">
                          <span
                            className={`rounded-full px-2 py-0.5 text-[9px] font-semibold uppercase tracking-[0.08em] ${meta.bg} ${meta.text}`}
                          >
                            {meta.label}
                          </span>
                          <span className="text-[10px] text-[#A0A8B4]">
                            {formatCompactDate(event.date.toISOString())}
                          </span>
                        </div>

                        <p className="mt-2 text-sm font-semibold text-[#26344A]">
                          {event.title}
                        </p>
                        <p className="mt-1 text-xs text-[#7B8798]">
                          {event.subtitle}
                        </p>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog
        open={isNotificationsOpen}
        onOpenChange={setIsNotificationsOpen}
      >
        <DialogTrigger asChild>
          <button
            type="button"
            aria-label="Abrir notificaciones"
            title="Notificaciones"
            className={[
              "relative flex h-10 w-10 items-center justify-center rounded-full border transition-all duration-200",
              unreadNotifications.length > 0
                ? "border-[#173B8F] bg-[#173B8F] text-white hover:border-[#102A66] hover:bg-[#102A66]"
                : "border-[#D7DEE7] bg-white text-[#667386] hover:border-[#C7D0DB] hover:bg-[#F3F5F8] hover:text-[#445166]",
            ].join(" ")}
          >
            <Bell className="h-[17px] w-[17px]" strokeWidth={1.8} />

            {unreadNotifications.length > 0 && (
              <span className="absolute -right-1 -top-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full border-2 border-white bg-[#102A66] px-1 text-[9px] font-bold leading-none text-white">
                {unreadNotifications.length > 99
                  ? "99+"
                  : unreadNotifications.length}
              </span>
            )}
          </button>
        </DialogTrigger>

        <DialogContent className="max-h-[85vh] overflow-hidden sm:max-w-xl">
          <DialogHeader>
            <div className="flex items-center justify-between gap-4">
              <div>
                <DialogTitle className="text-[#182A45]">
                  Notificaciones
                </DialogTitle>
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
                  className="text-xs text-[#173B8F] hover:bg-[#173B8F] hover:text-white"
                >
                  Marcar todas como leídas
                </Button>
              )}
            </div>
          </DialogHeader>

          <div className="max-h-[60vh] overflow-y-auto pr-1">
            {notifications.length === 0 ? (
              <div className="py-12 text-center">
                <Bell
                  className="mx-auto mb-3 h-7 w-7 text-[#B0B8C4]"
                  strokeWidth={1.5}
                />
                <p className="text-sm font-semibold text-[#26344A]">
                  No tienes notificaciones
                </p>
                <p className="mt-1 text-xs text-[#8792A3]">
                  Aquí aparecerán los avisos importantes.
                </p>
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
                          "mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full",
                          notification.read_at
                            ? "bg-transparent"
                            : "bg-[#173B8F]",
                        ].join(" ")}
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
  );
}
