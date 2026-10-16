import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
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
  Loader2,
  LogOut,
  Menu,
  Receipt,
  Search,
  UserRound,
  Wrench,
  X,
  CreditCard,
  Info,
  Lock,
  ShieldCheck,
} from "lucide-react";
import { Input } from "@/components/ui/input";

type InvoiceStatus = "pendiente" | "pagada" | "vencida" | "cancelada";
type PaymentStatus = "pending" | "succeeded" | "failed" | "canceled";

interface Invoice {
  id: string;
  project_id: string | null;
  company_id: string | null;
  user_id: string | null;
  numero_factura: string;
  fecha_emision: string | null;
  fecha_vencimiento: string | null;
  fecha_pago: string | null;
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
  estado: InvoiceStatus;
  document_path: string | null;
  created_at: string;
  updated_at: string | null;
}

interface Project {
  id: string;
  nombre: string;
}

interface Payment {
  id: string;
  invoice_id: string | null;
  amount: number;
  currency: string;
  status: PaymentStatus | string;
  description: string | null;
  paid_at: string | null;
  stripe_checkout_session_id: string | null;
  stripe_payment_intent_id: string | null;
  created_at: string;
}

type BillingDocument = { kind: "invoice"; data: Invoice };

type BillingFilter = "all" | "pendiente" | "pagada" | "vencida" | "cancelada";

const BILLING_FILTERS: BillingFilter[] = [
  "all",
  "pendiente",
  "pagada",
  "vencida",
  "cancelada",
];

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

const formatPaymentAmount = (
  amount: number | null | undefined,
  currency: string | null | undefined,
) => {
  const normalizedCurrency = String(currency || "EUR").toUpperCase();

  try {
    return new Intl.NumberFormat("es-ES", {
      style: "currency",
      currency: normalizedCurrency,
      minimumFractionDigits: 2,
    }).format(Number(amount ?? 0) / 100);
  } catch {
    return `${(Number(amount ?? 0) / 100).toFixed(2)} ${normalizedCurrency}`;
  }
};

const formatDate = (value?: string | null) =>
  value ? longDate.format(new Date(value)) : "Sin fecha";

const formatCompactDate = (value?: string | null) =>
  value ? compactDate.format(new Date(value)) : "Sin fecha";

const normalize = (value?: string | null) =>
  String(value || "").trim().toLowerCase();

const displayStatus = (status: InvoiceStatus | string | null | undefined) => {
  switch (normalize(status)) {
    case "pendiente":
      return "Pendiente";
    case "pagada":
      return "Pagada";
    case "vencida":
      return "Vencida";
    case "cancelada":
      return "Cancelada";
    default:
      return String(status || "");
  }
};

interface ParsedInvoiceDescription {
  title: string | null;
  detail: string | null;
  services: Array<{
    description: string;
    quantity: string | null;
    price: string | null;
  }>;
}

const parseInvoiceDescription = (
  value?: string | null,
): ParsedInvoiceDescription => {
  const raw = value?.trim() || "";

  if (!raw) {
    return { title: null, detail: null, services: [] };
  }

  const titleMatch = raw.match(
    /Título:\s*(.*?)(?=\s*Descripción detallada:|\s*Servicios incluidos:|$)/is,
  );

  const detailMatch = raw.match(
    /Descripción detallada:\s*(.*?)(?=\s*Servicios incluidos:|$)/is,
  );

  const servicesMatch = raw.match(/Servicios incluidos:\s*(.*)$/is);

  const services: ParsedInvoiceDescription["services"] = [];

  if (servicesMatch?.[1]) {
    const chunks = servicesMatch[1]
      .trim()
      .split(/\s+-\s+(?=[^|\n]+\s*\|\s*Cantidad:)/i)
      .map((item) => item.replace(/^[-•]\s*/, "").trim())
      .filter(Boolean);

    for (const chunk of chunks) {
      const serviceMatch = chunk.match(
        /^(.*?)\s*\|\s*Cantidad:\s*([^|]+?)\s*\|\s*Precio:\s*(.+)$/is,
      );

      if (serviceMatch) {
        services.push({
          description: serviceMatch[1].trim(),
          quantity: serviceMatch[2].trim(),
          price: serviceMatch[3].trim(),
        });
      } else {
        services.push({
          description: chunk,
          quantity: null,
          price: null,
        });
      }
    }
  }

  return {
    title: titleMatch?.[1]?.trim() || null,
    detail: detailMatch?.[1]?.trim() || null,
    services,
  };
};



const statusClasses = (status: string) => {
  switch (normalize(status)) {
    case "pagada":
      return "bg-[#ECF8F1] text-[#247A49] border-[#CDE8D8]";
    case "vencida":
      return "bg-[#FFF6E7] text-[#A56A00] border-[#F0DEB7]";
    case "cancelada":
      return "bg-[#F4F6F8] text-[#667386] border-[#E0E5EA]";
    default:
      return "bg-[#F3F0F6] text-[#4B3E57] border-[#DDD7E5]";
  }
};

const statusDot = (status: string) => {
  switch (normalize(status)) {
    case "pagada":
      return "bg-[#247A49]";
    case "vencida":
      return "bg-[#A56A00]";
    case "cancelada":
      return "bg-[#98A2B3]";
    default:
      return "bg-[#4B3E57]";
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

export default function Billing() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [location, setLocation] = useLocation();

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);

  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] =
    useState<BillingFilter>("all");

  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const [selectedDocument, setSelectedDocument] =
    useState<BillingDocument | null>(null);

  const [refreshing, setRefreshing] = useState(false);

  const isDetailMode = Boolean(selectedKey);

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

  const getDocumentKey = (document: BillingDocument) =>
    `${document.kind}:${document.data.id}`;

  const openDocument = useCallback((document: BillingDocument) => {
    const key = `${document.kind}:${document.data.id}`;

    window.history.pushState(
      {
        modiraBillingView: true,
        view: "billing-document",
        documentKey: key,
      },
      "",
      `${window.location.pathname}#invoice=${encodeURIComponent(key)}`,
    );

    setSelectedKey(key);
    setSelectedDocument(document);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  const closeDocument = useCallback(() => {
    window.history.replaceState(
      { modiraBillingView: false, view: "billing-list" },
      "",
      window.location.pathname,
    );

    setSelectedKey(null);
    setSelectedDocument(null);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  useEffect(() => {
    const syncView = () => {
      const hash = window.location.hash;

      if (!hash.startsWith("#invoice=")) {
        setSelectedKey(null);
        setSelectedDocument(null);
        return;
      }

      const key = decodeURIComponent(hash.slice("#invoice=".length));
      setSelectedKey(key);
    };

    syncView();

    window.addEventListener("popstate", syncView);
    window.addEventListener("hashchange", syncView);

    return () => {
      window.removeEventListener("popstate", syncView);
      window.removeEventListener("hashchange", syncView);
    };
  }, []);

  const loadBilling = useCallback(async () => {
    if (!user) return;

    setLoading(true);
    setError(null);

    try {
      const invoiceResult = await supabase
        .from("invoices")
        .select(
          [
            "id",
            "project_id",
            "company_id",
            "user_id",
            "numero_factura",
            "fecha_emision",
            "fecha_vencimiento",
            "fecha_pago",
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
        .eq("user_id", user.id)
        .order("fecha_emision", { ascending: false });

      if (invoiceResult.error) throw invoiceResult.error;

      const invoiceRows =
        (invoiceResult.data ?? []) as unknown as Invoice[];

      setInvoices(invoiceRows);
      const projectIds = Array.from(
        new Set(
          invoiceRows
            .map((invoice) => invoice.project_id)
            .filter((id): id is string => Boolean(id)),
        ),
      );

      if (projectIds.length > 0) {
        const { data: projectData, error: projectError } =
          await supabase
            .from("projects")
            .select("id,nombre")
            .in("id", projectIds);

        if (projectError) throw projectError;

        setProjects((projectData ?? []) as unknown as Project[]);
      } else {
        setProjects([]);
      }

      const invoiceIds = invoiceRows.map((invoice) => invoice.id);

      if (invoiceIds.length) {
        const { data: paymentData, error: paymentError } =
          await supabase
            .from("payments")
            .select(
              [
                "id",
                "invoice_id",
                "amount",
                "currency",
                "status",
                "description",
                "paid_at",
                "stripe_checkout_session_id",
                "stripe_payment_intent_id",
                "created_at",
              ].join(","),
            )
            .in("invoice_id", invoiceIds)
            .order("created_at", { ascending: false });

        if (paymentError) throw paymentError;

        setPayments((paymentData ?? []) as unknown as Payment[]);
      } else {
        setPayments([]);
      }
    } catch (loadError) {
      console.error(loadError);

      setError(
        loadError instanceof Error
          ? loadError.message
          : "No se pudo cargar la información de facturación.",
      );
    } finally {
      setLoading(false);
    }
  }, [user]);

  useEffect(() => {
    if (!user || authLoading) return;
    void loadBilling();
  }, [user, authLoading, loadBilling]);

  const allDocuments = useMemo<BillingDocument[]>(
    () => invoices.map((data) => ({ kind: "invoice" as const, data })),
    [invoices],
  );

  useEffect(() => {
    if (!selectedKey) return;

    const current = allDocuments.find(
      (document) => getDocumentKey(document) === selectedKey,
    );

    if (current) {
      setSelectedDocument(current);
    }
  }, [allDocuments, selectedKey]);

  const projectById = useMemo(
    () => new Map(projects.map((project) => [project.id, project])),
    [projects],
  );

  const paymentByInvoiceId = useMemo(() => {
    const map = new Map<string, Payment[]>();

    payments.forEach((payment) => {
      const key = payment.invoice_id;

      if (!key) return;

      const current = map.get(key) || [];
      current.push(payment);
      map.set(key, current);
    });

    return map;
  }, [payments]);

  const billingStats = useMemo(() => {
    const documents = invoices;

    return {
      total: documents.length,
      pending: documents.filter(
        (invoice) => normalize(invoice.estado) === "pendiente",
      ).length,
      paid: documents.filter(
        (invoice) => normalize(invoice.estado) === "pagada",
      ).length,
      overdue: documents.filter((invoice) => {
        const status = normalize(invoice.estado);
        return status === "vencida" || status === "impagada";
      }).length,
    };
  }, [invoices]);

  const totalBillingDocuments = billingStats.total;

  const filteredDocuments = useMemo(() => {
    const normalizedSearch = normalize(search);

    return allDocuments
      .filter((document) => {
        const status = normalize(document.data.estado);

        if (
          statusFilter !== "all" &&
          status !== normalize(statusFilter)
        ) {
          return false;
        }

        if (!normalizedSearch) return true;

        const searchValues = [
          document.data.numero_factura,
          document.data.descripcion,
          document.data.project_id
            ? projectById.get(document.data.project_id)?.nombre
            : "",
        ];

        return searchValues
          .map(normalize)
          .some((value) => value.includes(normalizedSearch));
      })
      .sort((a, b) => {
        const aDate = new Date(
          a.data.fecha_emision || a.data.created_at,
        ).getTime();

        const bDate = new Date(
          b.data.fecha_emision || b.data.created_at,
        ).getTime();

        return bDate - aDate;
      });
  }, [allDocuments, projectById, search, statusFilter]);

  const isOverdue = (document: BillingDocument) => {
    const { data } = document;

    if (
      data.estado === "pagada" ||
      data.estado === "cancelada"
    ) {
      return false;
    }

    if (!data.fecha_vencimiento) return false;

    return new Date(data.fecha_vencimiento).getTime() < Date.now();
  };

  const getDocumentNumber = (document: BillingDocument) =>
    document.data.numero_factura;

  const getDocumentAmount = (document: BillingDocument) =>
    Number(document.data.importe_a_pagar ?? 0);

  const getDocumentDescription = (document: BillingDocument) =>
    document.data.descripcion || "Factura";

  const getParsedDocumentDescription = (document: BillingDocument) =>
    parseInvoiceDescription(document.data.descripcion);

  const getDocumentTypeLabel = () => "Factura";

  const getAvailablePdfPath = (document: BillingDocument) =>
    document.data.document_path;

  const getPdfBucket = () => "invoices";

  const getSignedPdfUrl = async (
    document: BillingDocument,
    download = false,
  ) => {
    const path = getAvailablePdfPath(document);

    if (!path) {
      toast.error("Esta factura no tiene un PDF disponible.");
      return null;
    }

    const { data, error: storageError } = await supabase.storage
      .from(getPdfBucket())
      .createSignedUrl(
        path,
        60 * 10,
        download ? { download: true } : undefined,
      );

    if (storageError) {
      console.error(storageError);
      toast.error("No se pudo acceder al PDF de la factura.");
      return null;
    }

    if (!data?.signedUrl) {
      toast.error("No se pudo generar el enlace del PDF.");
      return null;
    }

    return data.signedUrl;
  };

  const handleViewPdf = async (document: BillingDocument) => {
    const url = await getSignedPdfUrl(document);

    if (url) {
      window.open(url, "_blank", "noopener,noreferrer");
    }
  };

  const handleDownloadPdf = async (document: BillingDocument) => {
    const url = await getSignedPdfUrl(document, true);

    if (url) {
      window.location.assign(url);
    }
  };

  const handleRefresh = async () => {
    setRefreshing(true);
    await loadBilling();
    setRefreshing(false);
  };

  const selectedPayments = selectedDocument
    ? paymentByInvoiceId.get(selectedDocument.data.id) || []
    : [];

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

        <main className={sidebarOpen ? "ml-[62px] min-h-screen lg:ml-[236px]" : "ml-[62px] min-h-screen"}>
          <ClientFloatingActions />

          <div className="mx-auto flex min-h-screen max-w-[1380px] items-center justify-center px-5 sm:px-8 lg:px-12">
            <div className="text-center">
              <Loader2 className="mx-auto mb-3 h-7 w-7 animate-spin text-[#173B8F]" />
              <p className="text-[12px] text-[#718096]">
                Cargando facturación...
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

        <main className={sidebarOpen ? "ml-[62px] min-h-screen lg:ml-[236px]" : "ml-[62px] min-h-screen"}>
          <ClientFloatingActions />

          <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
            <section className="mb-8 border-b border-[#E6EAF0] pb-8">
              <button
                type="button"
                onClick={closeDocument}
                className="mb-5 inline-flex items-center gap-1.5 text-[11px] font-medium text-[#718096] transition-colors hover:text-[#173B8F]"
              >
                <ArrowRight className="h-3.5 w-3.5 rotate-180" />
                Volver a facturación
              </button>

              {selectedDocument ? (
                <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
                  <div>
                    <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                      Área de Cliente
                    </p>
                    <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                      {getDocumentNumber(selectedDocument)}
                    </h1>
                    <p className="mt-1.5 text-sm text-[#718096]">
                      {getDocumentDescription(selectedDocument)}
                    </p>
                  </div>

                  <div className="flex flex-wrap items-center gap-2">
                    <span className="rounded-full border border-[#E0E5EA] bg-white px-3 py-1.5 text-[10px] font-semibold text-[#667386]">
                      {getDocumentTypeLabel()}
                    </span>

                    <span
                      className={[
                        "inline-flex rounded-full border px-3 py-1.5 text-[10px] font-semibold",
                        statusClasses(selectedDocument.data.estado),
                      ].join(" ")}
                    >
                      <span
                        className={[
                          "mr-2 mt-[3px] h-1.5 w-1.5 rounded-full",
                          statusDot(selectedDocument.data.estado),
                        ].join(" ")}
                      />
                      {displayStatus(selectedDocument.data.estado)}
                    </span>
                  </div>
                </div>
              ) : (
                <div className="py-6">
                  <Loader2 className="h-6 w-6 animate-spin text-[#173B8F]" />
                </div>
              )}
            </section>

            {error && !selectedDocument ? (
              <ErrorBlock message={error} />
            ) : selectedDocument ? (
              <BillingDetail
                document={selectedDocument}
                projectName={
                  selectedDocument.kind === "invoice" &&
                  selectedDocument.data.project_id
                    ? projectById.get(
                        selectedDocument.data.project_id,
                      )?.nombre
                    : undefined
                }
                payments={selectedPayments}
                onViewPdf={() => void handleViewPdf(selectedDocument)}
                onDownloadPdf={() =>
                  void handleDownloadPdf(selectedDocument)
                }
                hasPdf={Boolean(getAvailablePdfPath(selectedDocument))}
                overdue={isOverdue(selectedDocument)}
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

      <main className={sidebarOpen ? "ml-[62px] min-h-screen lg:ml-[236px]" : "ml-[62px] min-h-screen"}>
        <ClientFloatingActions />

        <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
          <section className="mb-8 border-b border-[#E6EAF0] pb-8">
            <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                  Área de Cliente
                </p>
                <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                  Facturación
                </h1>
                <p className="mt-1.5 max-w-2xl text-sm text-[#718096]">
                  Consulta tus facturas, importes, vencimientos, pagos y
                  documentación asociada.
                </p>
              </div>

              <button
                type="button"
                onClick={() => void handleRefresh()}
                disabled={refreshing}
                className="inline-flex items-center gap-2 rounded-full border border-[#DCE2E9] bg-white px-4 py-2 text-[11px] font-semibold text-[#667386] transition-colors hover:border-[#C6CFDA] hover:text-[#173B8F] disabled:opacity-50"
              >
                {refreshing ? (
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                ) : (
                  <ArrowRight className="h-3.5 w-3.5 rotate-90" />
                )}
                Actualizar
              </button>
            </div>
          </section>

          <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
            {[
              {
                label: "Total de facturas",
                value: billingStats.total,
                detail:
                  billingStats.total === 1
                    ? "Factura registrada"
                    : "Facturas registradas",
                icon: Receipt,
                active: billingStats.total > 0,
              },
              {
                label: "Facturas pendientes",
                value: billingStats.pending,
                detail: "Pendientes de pago",
                icon: Clock3,
                active: billingStats.pending > 0,
              },
              {
                label: "Facturas pagadas",
                value: billingStats.paid,
                detail: "Pagos confirmados",
                icon: Check,
                active: billingStats.paid > 0,
              },
              {
                label: "Facturas vencidas",
                value: billingStats.overdue,
                detail: "Pendientes fuera de plazo",
                icon: AlertCircle,
                active: billingStats.overdue > 0,
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
              eyebrow="Cartera de facturación"
              title="Todas tus facturas"
              action={
                <span className="text-[11px] text-[#8A95A5]">
                  {filteredDocuments.length} de {totalBillingDocuments}
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
                  placeholder="Buscar factura por número, descripción o periodo..."
                  className="h-full min-w-0 !border-0 !bg-transparent !p-0 text-[13px] text-[#344054] !shadow-none !outline-none placeholder:text-[#9AA4B2] focus:!border-0 focus:!outline-none focus:!ring-0 focus-visible:!border-0 focus-visible:!outline-none focus-visible:!ring-0 focus-visible:ring-offset-0"
                />
              </div>

              <div className="mt-5 flex flex-wrap items-center gap-x-3 gap-y-2.5">
                <span className="mr-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                  Estado
                </span>

                {BILLING_FILTERS.map((status) => {
                  const active = statusFilter === status;
                  const label =
                    status === "all" ? "Todos" : displayStatus(status);

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
              <ErrorBlock message={error} />
            ) : filteredDocuments.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-12 text-center">
                <Receipt
                  className="mx-auto mb-4 h-7 w-7 text-[#AAB3BF]"
                  strokeWidth={1.6}
                />

                <p className="text-[14px] font-semibold text-[#344054]">
                  {totalBillingDocuments
                    ? "No hay facturas que coincidan"
                    : "Todavía no tienes facturas"}
                </p>

                <p className="mx-auto mt-2 max-w-md text-[12px] leading-5 text-[#8792A2]">
                  {totalBillingDocuments
                    ? "Prueba con otro número, descripción, periodo o estado."
                    : "Cuando tengas una factura asociada a tu cuenta aparecerá en este apartado."}
                </p>
              </div>
            ) : (
              <div className="space-y-5">
                {filteredDocuments.map((document) => {
                  const number = getDocumentNumber(document);
                  const description = getDocumentDescription(document);
                  const amount = getDocumentAmount(document);
                  const overdue = isOverdue(document);
                  const pdfAvailable = Boolean(
                    getAvailablePdfPath(document),
                  );

                  const projectName =
                    document.kind === "invoice" &&
                    document.data.project_id
                      ? projectById.get(
                          document.data.project_id,
                        )?.nombre
                      : undefined;

                  return (
                    <article
                      key={getDocumentKey(document)}
                      className="group relative overflow-hidden rounded-[20px] border border-[#E1E7EE] bg-white transition-all duration-200 hover:-translate-y-[1px] hover:border-[#CDD6E0] hover:shadow-[0_14px_34px_rgba(24,42,69,0.07)]"
                    >
                      <div className="relative px-5 py-5 sm:px-7 sm:py-6">
                        <div className="flex items-start gap-6">
                          <div className="min-w-0 flex-1">
                            <div className="flex flex-wrap items-center gap-2.5">
                              <span
                                className={[
                                  "inline-flex h-2 w-2 shrink-0 rounded-full",
                                  statusDot(document.data.estado),
                                ].join(" ")}
                                aria-hidden="true"
                              />

                              <h3 className="min-w-0 text-[17px] font-semibold leading-tight tracking-[-0.015em] text-[#1F3048] sm:text-[18px]">
                                {number}
                              </h3>

                              <span className="rounded-full border border-[#E0E5EA] bg-white px-2.5 py-1 text-[10px] font-semibold leading-none text-[#667386]">
                                {getDocumentTypeLabel()}
                              </span>

                              <span
                                className={[
                                  "rounded-full border px-2.5 py-1 text-[10px] font-semibold leading-none",
                                  statusClasses(document.data.estado),
                                ].join(" ")}
                              >
                                {displayStatus(document.data.estado)}
                              </span>
                            </div>

                            {(() => {
                              const parsed = getParsedDocumentDescription(document);

                              if (
                                !parsed.title &&
                                !parsed.detail &&
                                parsed.services.length === 0
                              ) {
                                return (
                                  <p className="mt-3 max-w-3xl text-[12px] leading-5 text-[#718096]">
                                    {description}
                                  </p>
                                );
                              }

                              return (
                                <div className="mt-4 max-w-3xl space-y-2.5">
                                  {parsed.title && (
                                    <div className="flex flex-wrap gap-x-2 gap-y-1 text-[11px]">
                                      <span className="font-semibold text-[#8A95A5]">
                                        Título
                                      </span>
                                      <span className="text-[#536176]">
                                        {parsed.title}
                                      </span>
                                    </div>
                                  )}

                                  {parsed.detail && (
                                    <div className="text-[11px] leading-5">
                                      <span className="font-semibold text-[#8A95A5]">
                                        Descripción
                                      </span>
                                      <p className="mt-0.5 text-[#718096]">
                                        {parsed.detail}
                                      </p>
                                    </div>
                                  )}

                                  {parsed.services.length > 0 && (
                                    <div className="pt-1">
                                      <p className="mb-1.5 text-[9px] font-semibold uppercase tracking-[0.13em] text-[#98A2B3]">
                                        Servicios incluidos
                                      </p>
                                      <div className="space-y-1.5">
                                        {parsed.services.map((service, index) => (
                                          <div
                                            key={`${service.description}-${index}`}
                                            className="grid grid-cols-[minmax(0,1fr)_70px_90px] items-center gap-3 rounded-lg border border-[#EEF1F4] bg-[#FAFBFC] px-3 py-2"
                                          >
                                            <span className="min-w-0 text-[11px] text-[#536176]">
                                              {service.description}
                                            </span>
                                            <span className="text-right text-[10px] text-[#7A8595]">
                                              {service.quantity
                                                ? `x${service.quantity}`
                                                : "—"}
                                            </span>
                                            <span className="text-right text-[10px] font-semibold text-[#445166]">
                                              {service.price || "—"}
                                            </span>
                                          </div>
                                        ))}
                                      </div>
                                    </div>
                                  )}
                                </div>
                              );
                            })()}

                            {projectName && (
                              <p className="mt-2 text-[10px] font-medium uppercase tracking-[0.1em] text-[#98A2B3]">
                                Proyecto · {projectName}
                              </p>
                            )}


                            <div className="mt-5 flex flex-wrap items-center gap-x-6 gap-y-3">
                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Emisión
                                </p>
                                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                                  {formatCompactDate(
                                    document.data.fecha_emision,
                                  )}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Vencimiento
                                </p>
                                <p
                                  className={[
                                    "mt-1 text-[11px] font-medium",
                                    overdue
                                      ? "text-[#A56A00]"
                                      : "text-[#445166]",
                                  ].join(" ")}
                                >
                                  {formatCompactDate(
                                    document.data.fecha_vencimiento,
                                  )}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Total a pagar
                                </p>
                                <p className="mt-1 text-[11px] font-semibold text-[#26344A]">
                                  {formatCurrency(amount)}
                                </p>
                              </div>
                            </div>

                            {overdue && (
                              <div className="mt-4 inline-flex items-center gap-1.5 text-[9px] font-medium text-[#A56A00]">
                                <AlertCircle className="h-3 w-3" />
                                Fecha de vencimiento superada
                              </div>
                            )}

                            <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 border-t border-[#EEF1F4] pt-4 text-[11px]">
                              {document.data.fecha_pago && (
                                <>
                                  <span className="inline-flex items-center gap-1.5 text-[#7A8595]">
                                    <Check
                                      className="h-3.5 w-3.5 text-[#247A49]"
                                      strokeWidth={1.7}
                                    />
                                    Pagada el{" "}
                                    {formatCompactDate(
                                      document.data.fecha_pago,
                                    )}
                                  </span>

                                  <span className="hidden h-4 w-px bg-[#E5E9EE] sm:block" />
                                </>
                              )}

                              {pdfAvailable && (
                                <span className="inline-flex items-center gap-1.5 text-[#7A8595]">
                                  <Download
                                    className="h-3.5 w-3.5 text-[#9AA4B2]"
                                    strokeWidth={1.7}
                                  />
                                  PDF disponible
                                </span>
                              )}

                              <div className="ml-auto flex items-center gap-2">
                                {pdfAvailable && (
                                  <>
                                    <button
                                      type="button"
                                      onClick={() =>
                                        void handleViewPdf(document)
                                      }
                                      aria-label={`Ver PDF de ${number}`}
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
                                        void handleDownloadPdf(document)
                                      }
                                      aria-label={`Descargar PDF de ${number}`}
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
                                  onClick={() => openDocument(document)}
                                  className="inline-flex items-center gap-1.5 font-semibold text-[#173B8F] transition-all hover:gap-2 hover:text-[#102A66]"
                                >
                                  Consultar factura
                                  <ArrowRight className="h-3.5 w-3.5" />
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

function BillingDetail({
  document,
  projectName,
  payments,
  onViewPdf,
  onDownloadPdf,
  hasPdf,
  overdue,
}: {
  document: BillingDocument;
  projectName?: string;
  payments: Payment[];
  onViewPdf: () => void;
  onDownloadPdf: () => void;
  hasPdf: boolean;
  overdue: boolean;
}) {
  const data = document.data;

  const [pdfOpened, setPdfOpened] = useState(false);
  const [acknowledged, setAcknowledged] = useState(false);
  const [paymentLoading, setPaymentLoading] = useState(false);
  const subtotal = Number(data.subtotal ?? 0);
  const ivaImporte = Number(data.iva_importe ?? 0);
  const irpfImporte = Number(data.irpf_importe ?? 0);
  const grossAmount = Number(data.monto ?? 0);
  const amountToPay = Number(data.importe_a_pagar ?? 0);
  const normalizedInvoiceStatus = normalize(data.estado);

  const canPay =
    hasPdf &&
    (normalizedInvoiceStatus === "pendiente" ||
      normalizedInvoiceStatus === "vencida");

  const paymentReady =
    canPay &&
    pdfOpened &&
    acknowledged &&
    !paymentLoading;
  return (
    <div className="space-y-8">
      <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_320px]">
        <section className="border border-[#E3E8EE] bg-white p-5 sm:p-7">
          <div className="flex items-start justify-between gap-4">
            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
                Detalle de factura
              </p>

              <h2 className="mt-1 text-xl font-semibold tracking-tight text-[#182A45]">
                {data.descripcion || "Factura"}
              </h2>

              <p className="mt-1.5 text-[11px] text-[#8A95A5]">
                {document.data.numero_factura}
              </p>
            </div>

            {hasPdf && (
              <div className="flex shrink-0 items-center gap-2">
                <button
                  type="button"
                  onClick={() => {
  setPdfOpened(true);
  onViewPdf();
}}
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

          <div className="mt-7 border-y border-[#E7EBF0]">
            <div className="flex items-center justify-between gap-4 px-1 py-4">
              <span className="text-[11px] text-[#718096]">
                Base imponible
              </span>
              <span className="text-[11px] font-medium text-[#445166]">
                {formatCurrency(subtotal)}
              </span>
            </div>

            <div className="flex items-center justify-between gap-4 border-t border-[#EEF1F4] px-1 py-4">
              <span className="text-[11px] text-[#718096]">
                IVA{" "}
                {Number(data.iva_porcentaje ?? 0)}
                %
              </span>
              <span className="text-[11px] font-medium text-[#445166]">
                {formatCurrency(ivaImporte)}
              </span>
            </div>

            {Boolean(document.data.irpf_aplicado) && (
              <div className="flex items-center justify-between gap-4 border-t border-[#EEF1F4] px-1 py-4">
                <span className="text-[11px] text-[#718096]">
                  IRPF{" "}
                  {Number(data.irpf_porcentaje ?? 0)}
                  %
                </span>
                <span className="text-[11px] font-medium text-[#445166]">
                  − {formatCurrency(irpfImporte)}
                </span>
              </div>
            )}

            <div className="flex items-center justify-between gap-4 border-t border-[#EEF1F4] px-1 py-4">
              <span className="text-[11px] font-semibold text-[#536176]">
                Total bruto
              </span>
              <span className="text-[13px] font-semibold text-[#26344A]">
                {formatCurrency(grossAmount)}
              </span>
            </div>

            <div className="flex items-end justify-between gap-4 border-t border-[#E7EBF0] bg-[#F8FAFC] px-4 py-5">
              <div>
                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                  Importe a pagar
                </p>
                <p className="mt-1 text-[11px] text-[#718096]">
                  Cantidad exigible de la factura
                </p>
              </div>

              <span className="text-[22px] font-semibold tracking-tight text-[#182A45]">
                {formatCurrency(amountToPay)}
              </span>
            </div>
          </div>

          {data.descripcion && (
            <div className="mt-7 border-t border-[#EEF1F4] pt-6">
              {(() => {
                const parsed = parseInvoiceDescription(data.descripcion);

                if (
                  !parsed.title &&
                  !parsed.detail &&
                  parsed.services.length === 0
                ) {
                  return (
                    <>
                      <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                        Descripción
                      </p>
                      <p className="mt-2 whitespace-pre-line text-[12px] leading-5 text-[#718096]">
                        {data.descripcion}
                      </p>
                    </>
                  );
                }

                return (
                  <div>
                    <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                      Contenido de la factura
                    </p>

                    <div className="mt-4 space-y-4">
                      {parsed.title && (
                        <div>
                          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                            Título
                          </p>
                          <p className="mt-1 text-[12px] font-medium text-[#445166]">
                            {parsed.title}
                          </p>
                        </div>
                      )}

                      {parsed.detail && (
                        <div>
                          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                            Descripción detallada
                          </p>
                          <p className="mt-1 whitespace-pre-line text-[12px] leading-5 text-[#718096]">
                            {parsed.detail}
                          </p>
                        </div>
                      )}

                      {parsed.services.length > 0 && (
                        <div>
                          <p className="mb-2 text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                            Servicios incluidos
                          </p>

                          <div className="overflow-hidden border border-[#E7EBF0]">
                            <div className="grid grid-cols-[minmax(0,1fr)_80px_110px] border-b border-[#E7EBF0] bg-[#F8FAFC] px-4 py-3 text-[9px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">
                              <span>Servicio</span>
                              <span className="text-right">Cantidad</span>
                              <span className="text-right">Precio</span>
                            </div>

                            <div className="divide-y divide-[#EEF1F4]">
                              {parsed.services.map((service, index) => (
                                <div
                                  key={`${service.description}-${index}`}
                                  className="grid grid-cols-[minmax(0,1fr)_80px_110px] px-4 py-3"
                                >
                                  <span className="pr-4 text-[11px] text-[#536176]">
                                    {service.description}
                                  </span>
                                  <span className="text-right text-[11px] text-[#718096]">
                                    {service.quantity || "—"}
                                  </span>
                                  <span className="text-right text-[11px] font-medium text-[#445166]">
                                    {service.price || "—"}
                                  </span>
                                </div>
                              ))}
                            </div>
                          </div>
                        </div>
                      )}
                    </div>
                  </div>
                );
              })()}
            </div>
          )}
        </section>

        <aside className="space-y-5">
          <section className="border border-[#E3E8EE] bg-white p-5">
            <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
              Información
            </p>

            <div className="mt-5 space-y-4">
              <DetailInfo
                label="Tipo"
                value="Factura"
              />

              <DetailInfo
                label="Número"
                value={document.data.numero_factura}
              />

              <DetailInfo
                label="Emisión"
                value={formatDate(data.fecha_emision)}
              />

              <DetailInfo
                label="Vencimiento"
                value={formatDate(data.fecha_vencimiento)}
                valueClass={overdue ? "text-[#A56A00]" : undefined}
              />

              {data.fecha_pago && (
                <DetailInfo
                  label="Fecha de pago"
                  value={formatDate(data.fecha_pago)}
                  valueClass="text-[#247A49]"
                />
              )}

              {projectName && (
                <DetailInfo label="Proyecto" value={projectName} />
              )}
            </div>
          </section>

          {overdue && (
            <div className="border border-[#F0DEB7] bg-[#FFF7E8] px-5 py-4">
              <div className="flex items-start gap-3">
                <AlertCircle
                  className="mt-0.5 h-4 w-4 shrink-0 text-[#A56A00]"
                  strokeWidth={1.7}
                />

                <p className="text-[11px] leading-5 text-[#8B640F]">
                  La fecha de vencimiento de esta factura ya ha sido superada.
                </p>
              </div>
            </div>
          )}
        </aside>
      </div>

      <section className="border border-[#E3E8EE] bg-white p-5 sm:p-7">
        <div className="flex items-end justify-between gap-4">
          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
              Pagos
            </p>
            <h2 className="mt-1 text-[17px] font-semibold tracking-tight text-[#182A45]">
              Historial de pagos
            </h2>
          </div>

          <span className="text-[11px] text-[#8A95A5]">
            {payments.length}{" "}
            {payments.length === 1 ? "registro" : "registros"}
          </span>
        </div>

        {payments.length === 0 ? (
          <div className="mt-5 border-y border-[#EEF1F4] py-7 text-center">
            <Clock3
              className="mx-auto mb-3 h-5 w-5 text-[#AAB3BF]"
              strokeWidth={1.6}
            />

            <p className="text-[12px] font-medium text-[#536176]">
              No hay pagos registrados
            </p>

            <p className="mt-1 text-[11px] text-[#8792A2]">
              Los pagos confirmados se mostrarán aquí.
            </p>
          </div>
        ) : (
          <div className="mt-5 overflow-x-auto border border-[#E7EBF0]">
            <div className="min-w-[680px]">
              <div className="grid grid-cols-[1fr_110px_110px_130px] border-b border-[#E7EBF0] bg-[#F8FAFC] px-4 py-3 text-[9px] font-semibold uppercase tracking-[0.13em] text-[#8A95A5]">
                <span>Descripción</span>
                <span>Estado</span>
                <span className="text-right">Importe</span>
                <span className="text-right">Fecha</span>
              </div>

              <div className="divide-y divide-[#EEF1F4]">
                {payments.map((payment) => (
                  <div
                    key={payment.id}
                    className="grid grid-cols-[1fr_110px_110px_130px] items-center px-4 py-4"
                  >
                    <div>
                      <p className="text-[11px] font-medium text-[#445166]">
                        {payment.description || "Pago de factura"}
                      </p>

                      {payment.stripe_payment_intent_id && (
                        <p className="mt-1 text-[9px] text-[#98A2B3]">
                          PaymentIntent registrado
                        </p>
                      )}
                    </div>

                    <span
                      className={[
                        "w-fit rounded-full border px-2.5 py-1 text-[9px] font-semibold",
                        payment.status === "succeeded"
                          ? "border-[#CDE8D8] bg-[#ECF8F1] text-[#247A49]"
                          : payment.status === "failed" ||
                              payment.status === "canceled"
                            ? "border-[#E0E5EA] bg-[#F4F6F8] text-[#667386]"
                            : "border-[#DDD7E5] bg-[#F3F0F6] text-[#4B3E57]",
                      ].join(" ")}
                    >
                      {payment.status === "succeeded"
                        ? "Confirmado"
                        : payment.status === "failed"
                          ? "Fallido"
                          : payment.status === "canceled"
                            ? "Cancelado"
                            : "Pendiente"}
                    </span>

                    <span className="text-right text-[11px] font-semibold text-[#26344A]">
                      {formatPaymentAmount(payment.amount, payment.currency)}
                    </span>

                    <span className="text-right text-[11px] text-[#718096]">
                      {formatCompactDate(
                        payment.paid_at || payment.created_at,
                      )}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}
      </section>

{canPay && (
  <PaymentAcknowledgementCard
    amount={amountToPay}
    pdfOpened={pdfOpened}
    acknowledged={acknowledged}
    paymentLoading={paymentLoading}
    paymentReady={paymentReady}
    onOpenPdf={() => {
      setPdfOpened(true);
      onViewPdf();
    }}
    onAcknowledgedChange={setAcknowledged}
    onPay={async () => {
      if (!paymentReady) return;

      setPaymentLoading(true);

      try {
        // 1. Registrar la aceptación del documento actual
        const {
          data: acknowledgement,
          error: acknowledgementError,
        } = await supabase.rpc(
          "record_invoice_document_acknowledgement",
          {
            p_invoice_id: data.id,
          },
        );

        if (acknowledgementError) {
          throw new Error(
            acknowledgementError.message ||
              "No se ha podido registrar la aceptación del documento.",
          );
        }

        if (!acknowledgement?.id) {
          throw new Error(
            "No se ha podido registrar la aceptación del documento.",
          );
        }

        // 2. Crear Checkout Session en Stripe
        const {
          data: checkoutData,
          error: checkoutError,
        } = await supabase.functions.invoke(
          "create-checkout-session",
          {
            body: {
              invoice_id: data.id,
            },
          },
        );

        if (checkoutError) {
          throw new Error(
            checkoutError.message ||
              "No se ha podido iniciar el pago.",
          );
        }

        if (!checkoutData?.checkout_url) {
          throw new Error(
            "Stripe no ha devuelto una URL de pago.",
          );
        }

        // 3. Redirigir a Stripe
        window.location.assign(
          checkoutData.checkout_url,
        );
      } catch (paymentError) {
        console.error(
          "Error iniciando pago:",
          paymentError,
        );

        toast.error(
          paymentError instanceof Error
            ? paymentError.message
            : "No se ha podido iniciar el pago.",
        );

        setPaymentLoading(false);
      }
    }}
  />
)}

    </div>
  );
}
function PaymentAcknowledgementCard({
  amount,
  pdfOpened,
  acknowledged,
  paymentLoading,
  paymentReady,
  onOpenPdf,
  onAcknowledgedChange,
  onPay,
}: {
  amount: number;
  pdfOpened: boolean;
  acknowledged: boolean;
  paymentLoading: boolean;
  paymentReady: boolean;
  onOpenPdf: () => void;
  onAcknowledgedChange: (value: boolean) => void;
  onPay: () => void;
}) {
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
            Pago seguro
          </p>

          <h2 className="mt-1 text-[17px] font-semibold tracking-tight text-[#182A45]">
            Pagar factura
          </h2>

          <p className="mt-1.5 text-[12px] leading-5 text-[#718096]">
            Antes de realizar el pago, consulta el documento PDF
            correspondiente a esta factura.
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
            La información mostrada en esta pantalla tiene carácter
            meramente informativo. El documento PDF adjunto constituye
            el documento de referencia de la factura y contiene la
            información fiscal y legal correspondiente.
          </p>
        </div>
      </div>

      <div className="mt-5">
        <button
          type="button"
          onClick={onOpenPdf}
          className="inline-flex items-center gap-2 rounded-full border border-[#DCE2E9] bg-white px-4 py-2.5 text-[11px] font-semibold text-[#173B8F] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC]"
        >
          <FileText
            className="h-3.5 w-3.5"
            strokeWidth={1.7}
          />
          {pdfOpened
            ? "Volver a consultar PDF"
            : "Consultar PDF antes de pagar"}
        </button>
      </div>

      <label
        className={[
          "mt-5 flex cursor-pointer items-start gap-3 border p-4 transition-colors",
          acknowledged
            ? "border-[#C9D7EE] bg-[#F5F8FD]"
            : "border-[#E4E9EF] bg-white hover:border-[#CCD5E0]",
        ].join(" ")}
      >
        <input
          type="checkbox"
          checked={acknowledged}
          onChange={(event) =>
            onAcknowledgedChange(
              event.target.checked,
            )
          }
          disabled={!pdfOpened || paymentLoading}
          className="mt-0.5 h-4 w-4 shrink-0 accent-[#173B8F]"
        />

        <span className="text-[11px] leading-5 text-[#536176]">
          He leído el documento PDF correspondiente a esta factura
          y declaro haber tenido acceso a su contenido, incluyendo
          la información fiscal, legal y las condiciones indicadas
          en el mismo.
        </span>
      </label>

      <div className="mt-6 flex flex-col gap-4 border-t border-[#E7EBF0] pt-5 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            Importe a pagar
          </p>

          <p className="mt-1 text-xl font-semibold tracking-tight text-[#182A45]">
            {formatCurrency(amount)}
          </p>
        </div>

        <button
          type="button"
          onClick={onPay}
          disabled={!paymentReady}
          className={[
            "inline-flex items-center justify-center gap-2 rounded-full px-5 py-3 text-[11px] font-semibold transition-all",
            paymentReady
              ? "bg-[#173B8F] text-white hover:bg-[#102A66]"
              : "cursor-not-allowed bg-[#E8EDF4] text-[#98A2B3]",
          ].join(" ")}
        >
          {paymentLoading ? (
            <>
              <Loader2
                className="h-3.5 w-3.5 animate-spin"
                strokeWidth={1.8}
              />
              Preparando pago...
            </>
          ) : (
            <>
              <CreditCard
                className="h-3.5 w-3.5"
                strokeWidth={1.7}
              />
              Pagar factura
            </>
          )}
        </button>
      </div>

      <div className="mt-4 flex items-center justify-end gap-1.5 text-[10px] text-[#8A95A5]">
        <Lock
          className="h-3 w-3"
          strokeWidth={1.7}
        />
        Pago procesado de forma segura mediante Stripe
      </div>
    </section>
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

function ErrorBlock({ message }: { message: string }) {
  return (
    <div className="border-y border-[#E7EBF0] py-8">
      <div className="flex items-start gap-3">
        <AlertCircle
          className="mt-0.5 h-5 w-5 shrink-0 text-[#B53A3A]"
          strokeWidth={1.7}
        />

        <div>
          <p className="text-[13px] font-semibold text-[#26344A]">
            No se pudo cargar la facturación
          </p>

          <p className="mt-1 text-[12px] leading-5 text-[#718096]">
            {message}
          </p>
        </div>
      </div>
    </div>
  );
}
