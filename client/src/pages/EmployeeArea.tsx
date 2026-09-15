import { useAuth } from "@/contexts/AuthContext";
import { supabase } from "@/lib/supabase";
import { useEffect, useState } from "react";
import { useLocation } from "wouter";
import EmployeeAreaHeader from "@/components/EmployeeAreaHeader";
import EmployeeProjects from "@/components/EmployeeProjects";
import { Textarea } from "@/components/ui/textarea";

import { Card } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";

import {
  Users,
  UserCog,
  Building2,
  ClipboardList,
  Check,
  X,
  Search,
  RefreshCw,
  AlertCircle,
  User,
  FileText,
  Upload,
  Eye,
  Loader2,
  Download,
  Plus,
  Pencil,
  Trash2,
  Save,
} from "lucide-react";

import { format } from "date-fns";
import { es } from "date-fns/locale";
import { toast } from "sonner";

export default function EmployeeArea() {
  const { user, signOut } = useAuth();
  const [, setLocation] = useLocation();

  // ============================================================
  // ESTADO GENERAL
  // ============================================================

  const [projectChangeRequests, setProjectChangeRequests] =
    useState<any[]>([]);

  const [loadingProjectChangeRequests, setLoadingProjectChangeRequests] =
    useState(false);

  const [processingProjectChangeRequest, setProcessingProjectChangeRequest] =
    useState<string | null>(null);

  const [selectedProjectChangeRequest, setSelectedProjectChangeRequest] =
    useState<any | null>(null);

  const [projectChangeReviewNotes, setProjectChangeReviewNotes] =
    useState("");

  // ============================================================
  // SOLICITUDES DE CAMBIO DE PROYECTOS
  // ============================================================

  const loadProjectChangeRequests = async () => {
    if (!user) {
      setProjectChangeRequests([]);
      return;
    }

    try {
      setLoadingProjectChangeRequests(true);

      const {
        data: projectChangeRequestsData,
        error: projectChangeRequestsError,
      } = await supabase.rpc(
        "get_worker_project_change_requests"
      );

      if (projectChangeRequestsError) {
        console.error(
          "[EmployeeArea] Error loading project change requests:",
          projectChangeRequestsError
        );

        setProjectChangeRequests([]);

        return;
      }

      setProjectChangeRequests(
        projectChangeRequestsData || []
      );
    } catch (error: any) {
      console.error(
        "[EmployeeArea] Unexpected error loading project change requests:",
        error
      );

      setProjectChangeRequests([]);
    } finally {
      setLoadingProjectChangeRequests(false);
    }
  };

  // ============================================================
  // CARGAR SOLICITUDES AL INICIAR / CAMBIAR USUARIO
  // ============================================================

  useEffect(() => {
    loadProjectChangeRequests();
  }, [user]);

  // ============================================================
  // RESOLVER SOLICITUD DE CAMBIO DE PROYECTO
  // ============================================================

  const handleResolveProjectChangeRequest = async (
    requestId: string,
    action:
      | "in_review"
      | "accepted"
      | "rejected"
      | "completed",
    reviewNotes?: string
  ) => {
    try {
      setProcessingProjectChangeRequest(requestId);

      const {
        data,
        error,
      } = await supabase.rpc(
        "resolve_project_change_request",
        {
          p_request_id: requestId,
          p_action: action,
          p_review_notes:
            reviewNotes?.trim() || null,
        }
      );

      if (error) {
        throw error;
      }

      /*
       * Actualizamos inmediatamente la solicitud que tenemos
       * en memoria para que la interfaz no tenga que esperar
       * a una nueva carga.
       */
      setProjectChangeRequests((current) =>
        current.map((request) =>
          request.id === requestId
            ? {
                ...request,
                ...(data || {}),
              }
            : request
        )
      );

      setSelectedProjectChangeRequest(null);
      setProjectChangeReviewNotes("");

      /*
       * Si EmployeeArea ya dispone de loadData(), la utilizamos
       * para refrescar también el resto de información del área.
       *
       * Después volvemos a cargar específicamente las solicitudes
       * para asegurarnos de que el estado mostrado coincide con
       * Supabase.
       */
      if (typeof loadData === "function") {
        await loadData();
      }

      await loadProjectChangeRequests();

      toast.success(
        "Solicitud actualizada correctamente."
      );
    } catch (error: any) {
      console.error(
        "[EmployeeArea] Error resolving project change request:",
        error
      );

      toast.error(
        error?.message ||
          "No se pudo actualizar la solicitud."
      );
    } finally {
      setProcessingProjectChangeRequest(null);
    }
  };

  const [workerName, setWorkerName] = useState("");
  const [loading, setLoading] = useState(true);

  const [activeTab, setActiveTab] = useState<
    | "projects"
    | "clients"
    | "quotations"
    | "billing"
    | "audits"
    | "tickets"
    | "ai"
  >("projects");

  // ============================================================
  // EMPRESAS / PROYECTOS
  // ============================================================

  const [companies, setCompanies] = useState<any[]>([]);
  const [projects, setProjects] = useState<any[]>([]);
// ============================================================
// HITOS — PRUEBA PROVISIONAL
// ============================================================

const [selectedMilestoneProjectId, setSelectedMilestoneProjectId] =
  useState("");

const [projectMilestones, setProjectMilestones] =
  useState<any[]>([]);

const [projectProgress, setProjectProgress] =
  useState<any | null>(null);

const [loadingMilestones, setLoadingMilestones] =
  useState(false);

const [creatingMilestone, setCreatingMilestone] =
  useState(false);

const [milestoneForm, setMilestoneForm] = useState({
  nombre: "",
  descripcion: "",
  fecha_prevista: "",
});
// ============================================================
// HITOS — CARGAR HITOS Y PROGRESO
// ============================================================

const loadProjectMilestones = async (projectId: string) => {
  if (!projectId) {
    setProjectMilestones([]);
    setProjectProgress(null);
    return;
  }

  try {
    setLoadingMilestones(true);

    // --------------------------------------------------------
    // HITOS
    // --------------------------------------------------------

    const {
      data: milestonesData,
      error: milestonesError,
    } = await supabase
      .from("project_milestones")
      .select("*")
      .eq("project_id", projectId)
      .order("orden", { ascending: true })
      .order("created_at", { ascending: true });

    if (milestonesError) {
      throw milestonesError;
    }

    setProjectMilestones(milestonesData || []);

    // --------------------------------------------------------
    // PROGRESO
    // --------------------------------------------------------

    const {
      data: progressData,
      error: progressError,
    } = await supabase
      .from("project_progress")
      .select(
        "project_id, total_milestones, completed_milestones, progress_percentage"
      )
      .eq("project_id", projectId)
      .maybeSingle();

    if (progressError) {
      throw progressError;
    }

    setProjectProgress(progressData || null);
  } catch (error: any) {
    console.error(
      "[EmployeeArea] Error loading project milestones:",
      error
    );

    setProjectMilestones([]);
    setProjectProgress(null);

    toast.error(
      error?.message ||
      "No se pudieron cargar los hitos del proyecto."
    );
  } finally {
    setLoadingMilestones(false);
  }
};
// ============================================================
// HITOS — CREAR
// ============================================================

const handleCreateMilestone = async () => {
  if (!selectedMilestoneProjectId) {
    toast.error("Selecciona un proyecto.");
    return;
  }

  if (!milestoneForm.nombre.trim()) {
    toast.error("Escribe el nombre del hito.");
    return;
  }

  if (!milestoneForm.fecha_prevista) {
    toast.error("Selecciona una fecha prevista.");
    return;
  }

  try {
    setCreatingMilestone(true);

    const {
      data,
      error,
    } = await supabase.rpc(
      "create_project_milestone",
      {
        p_project_id: selectedMilestoneProjectId,
        p_nombre: milestoneForm.nombre.trim(),
        p_descripcion:
          milestoneForm.descripcion.trim() || null,
        p_fecha_prevista: new Date(
          milestoneForm.fecha_prevista
        ).toISOString(),
      }
    );

    if (error) {
      throw error;
    }

    console.log(
      "[EmployeeArea] Milestone created:",
      data
    );

    setMilestoneForm({
      nombre: "",
      descripcion: "",
      fecha_prevista: "",
    });

    await loadProjectMilestones(
      selectedMilestoneProjectId
    );

    toast.success("Hito creado correctamente.");
  } catch (error: any) {
    console.error(
      "[EmployeeArea] Error creating milestone:",
      error
    );

    toast.error(
      error?.message ||
      "No se pudo crear el hito."
    );
  } finally {
    setCreatingMilestone(false);
  }
};
// ============================================================
// HITOS — CAMBIAR ESTADO
// ============================================================

const handleChangeMilestoneStatus = async (
  milestoneId: string,
  estado: "pendiente" | "en_curso" | "completado"
) => {
  try {
    const {
      data,
      error,
    } = await supabase.rpc(
      "set_project_milestone_status",
      {
        p_milestone_id: milestoneId,
        p_estado: estado,
      }
    );

    if (error) {
      throw error;
    }

    console.log(
      "[EmployeeArea] Milestone status updated:",
      data
    );

    await loadProjectMilestones(
      selectedMilestoneProjectId
    );

    toast.success(
      `Hito actualizado a "${estado}".`
    );
  } catch (error: any) {
    console.error(
      "[EmployeeArea] Error updating milestone status:",
      error
    );

    toast.error(
      error?.message ||
      "No se pudo actualizar el estado del hito."
    );
  }
};
  // ============================================================
  // PRESUPUESTOS COMERCIALES
  // ============================================================

  const [quotations, setQuotations] = useState<any[]>([]);
  const [quotationSearch, setQuotationSearch] = useState("");
  const [quotationCompanyFilter, setQuotationCompanyFilter] =
    useState("all");
  const [quotationProjectFilter, setQuotationProjectFilter] =
    useState("all");
  const [quotationStatusFilter, setQuotationStatusFilter] =
    useState("all");

  const [uploadingQuotationPdf, setUploadingQuotationPdf] =
    useState<string | null>(null);

  const [openingQuotationPdf, setOpeningQuotationPdf] =
    useState<string | null>(null);

  const [quotationClients, setQuotationClients] =
    useState<any[]>([]);

  // ============================================================
  // CREAR PROYECTO DESDE EMPLEADO
  // ============================================================

  const [showCreateProject, setShowCreateProject] =
    useState(false);

  const [creatingProject, setCreatingProject] =
    useState(false);

  const [projectError, setProjectError] =
    useState("");

  const [projectsRefreshKey, setProjectsRefreshKey] =
    useState(0);

  const [projectForm, setProjectForm] = useState({
    company_id: "",
    client_id: "",
    nombre: "",
    descripcion: "",
    fecha_inicio: "",
    fecha_fin: "",
  });

  // ============================================================
  // FORMULARIO DE PRESUPUESTO
  // ============================================================

  const [showQuotationForm, setShowQuotationForm] =
    useState(false);

  const [editingQuotation, setEditingQuotation] =
    useState<any | null>(null);

  const [savingQuotation, setSavingQuotation] =
    useState(false);

  const [quotationError, setQuotationError] =
    useState("");

  const [quotationPdfFile, setQuotationPdfFile] =
    useState<File | null>(null);

  const [quotationForm, setQuotationForm] = useState({
    company_id: "",
    project_id: "",
    client_id: "",
    numero_presupuesto: "",
    titulo: "",
    descripcion_detallada: "",
    servicios_incluidos: [
      {
        descripcion: "",
        cantidad: 1,
        precio: 0,
      },
    ],
    precio_base: "",
    iva_porcentaje: "21",
    estado: "Pendiente",
    fecha_emision: "",
    fecha_validez: "",
    notas: "",
  });

  // ============================================================
  // CLIENTES / PERFILES
  // ============================================================

  const [profiles, setProfiles] = useState<any[]>([]);
  const [profileSearch, setProfileSearch] = useState("");

  const [selectedProfile, setSelectedProfile] =
    useState<any | null>(null);

  const [selectedProfileCompanyId, setSelectedProfileCompanyId] =
    useState("");

  const [savingProfileCompany, setSavingProfileCompany] =
    useState(false);

  // ============================================================
  // SOLICITUDES DE CAMBIO DE EMPRESA
  // ============================================================

  const [companyChangeRequests, setCompanyChangeRequests] =
    useState<any[]>([]);

  const [processingCompanyRequest, setProcessingCompanyRequest] =
    useState<string | null>(null);

  // ============================================================
  // FACTURAS
  // ============================================================

  const [invoices, setInvoices] = useState<any[]>([]);

  const [invoiceCompanyFilter, setInvoiceCompanyFilter] =
    useState("all");

  const [invoiceProjectFilter, setInvoiceProjectFilter] =
    useState("all");

  const [showCreateInvoice, setShowCreateInvoice] =
    useState(false);

  const [editingInvoice, setEditingInvoice] = useState<any | null>(null);
  const [selectedInvoice, setSelectedInvoice] = useState<any | null>(null);
  const [openingInvoicePdf, setOpeningInvoicePdf] = useState<string | null>(null);
  const [deletingInvoice, setDeletingInvoice] = useState<string | null>(null);

  const [generatedInvoiceNumber, setGeneratedInvoiceNumber] =
    useState("");

  const [creatingInvoice, setCreatingInvoice] =
    useState(false);

  const [invoiceError, setInvoiceError] =
    useState("");

  const [invoiceForm, setInvoiceForm] = useState({
    company_id: "",
    project_id: "",
    user_id: "",
    numero_factura: "",
    titulo: "",
    descripcion_detallada: "",
    servicios_incluidos: [
      { descripcion: "", cantidad: 1, precio: 0 },
    ],
    precio_base: "",
    iva_porcentaje: "21",
    irpf_aplicado: false,
    irpf_porcentaje: "0",
    estado: "pendiente",
    fecha_emision: "",
    fecha_vencimiento: "",
    notas: "",
  });

  const [invoicePdfFile, setInvoicePdfFile] = useState<File | null>(null);

  // ============================================================
  // TICKETS
  // ============================================================

  const [tickets, setTickets] = useState<any[]>([]);

  // ============================================================
  // AUDITORÍAS
  // ============================================================

  const [auditRequests, setAuditRequests] =
    useState<any[]>([]);

  // ============================================================
  // CONVERSACIONES IA
  // ============================================================

  const [aiConversations, setAiConversations] =
    useState<any[]>([]);

  const [aiMessages, setAiMessages] =
    useState<any[]>([]);

  const [selectedAIConversation, setSelectedAIConversation] =
    useState<any | null>(null);

  const [loadingAIConversation, setLoadingAIConversation] =
    useState(false);

  // ============================================================
  // FILTROS FACTURACIÓN
  // ============================================================

  const filteredInvoices = invoices
    .filter((inv) => {
      const companyMatch =
        invoiceCompanyFilter === "all" ||
        inv.company_id === invoiceCompanyFilter;

      const projectMatch =
        invoiceProjectFilter === "all" ||
        inv.project_id === invoiceProjectFilter;

      return companyMatch && projectMatch;
    })
    .sort((a, b) => {
      const dateA = new Date(a.created_at || a.fecha_emision || 0).getTime();
      const dateB = new Date(b.created_at || b.fecha_emision || 0).getTime();
      return dateB - dateA;
    });

  const invoiceProjects = projects.filter((project) =>
    invoices.some(
      (invoice) => invoice.project_id === project.id
    )
  );
  // ============================================================
  // FACTURACIÓN — DATOS CALCULADOS DEL FORMULARIO
  // ============================================================

  const createInvoiceProjects = invoiceForm.company_id
    ? projects.filter(
      (project) =>
        String(project.company_id) ===
        String(invoiceForm.company_id)
    )
    : [];

  const selectedInvoiceProject = projects.find(
    (project) =>
      String(project.id) ===
      String(invoiceForm.project_id)
  );

  const selectedInvoiceUser = selectedInvoiceProject?.user_id
    ? profiles.find(
      (profile) =>
        String(profile.id) ===
        String(selectedInvoiceProject.user_id)
    )
    : null;

  const invoiceSubtotal = Number(
    invoiceForm.precio_base || 0
  );

  const invoiceIvaPercentage = Number(
    invoiceForm.iva_porcentaje || 0
  );

  const invoiceIvaAmount =
    invoiceSubtotal *
    (invoiceIvaPercentage / 100);

  const invoiceTotal =
    invoiceSubtotal +
    invoiceIvaAmount;

  const filteredQuotations = quotations
    .filter((quotation) => {
      const search = quotationSearch.trim().toLowerCase();

      const companyMatch =
        quotationCompanyFilter === "all" ||
        quotation.company_id === quotationCompanyFilter;

      const projectMatch =
        quotationProjectFilter === "all" ||
        quotation.project_id === quotationProjectFilter;

      const statusMatch =
        quotationStatusFilter === "all" ||
        String(quotation.estado || "").toLowerCase() === quotationStatusFilter;

      const companyName =
        companies.find((company) => company.id === quotation.company_id)?.company_name || "";

      const projectName =
        projects.find((project) => project.id === quotation.project_id)?.nombre || "";

      const searchMatch = !search || [
        quotation.numero_presupuesto,
        quotation.titulo,
        quotation.descripcion_detallada,
        quotation.client_id,
        quotationClients.find((client) => client.id === quotation.client_id)?.nombre,
        companyName,
        projectName,
      ].some((value) => String(value || "").toLowerCase().includes(search));

      return companyMatch && projectMatch && statusMatch && searchMatch;
    })
    .sort((a, b) => {
      const dateA = new Date(a.created_at || a.fecha_emision || 0).getTime();
      const dateB = new Date(b.created_at || b.fecha_emision || 0).getTime();
      return dateB - dateA;
    });

  // ============================================================
  // CARGAR DATOS
  // ============================================================

  const loadData = async () => {
    if (!user) return;

    try {
      setLoading(true);

      // ========================================================
      // 1. DATOS DEL TRABAJADOR
      // ========================================================

      const {
        data: worker,
        error: workerError,
      } = await supabase
        .from("workers")
        .select("display_name")
        .eq("auth_user_id", user.id)
        .single();

      if (workerError) {
        console.error(
          "[EmployeeArea] Error loading worker:",
          workerError
        );
      } else if (worker) {
        setWorkerName(
          worker.display_name || "Trabajador"
        );
      }

      // ========================================================
      // 2. EMPRESAS
      // ========================================================

      const {
        data: companiesData,
        error: companiesError,
      } = await supabase
        .from("companies")
        .select(
          "id, company_name, subscription_plan, subscription_status"
        )
        .order("company_name", {
          ascending: true,
        });

      if (companiesError) {
        console.error(
          "[EmployeeArea] Error loading companies:",
          companiesError
        );
      } else {
        setCompanies(companiesData || []);
      }

      // ========================================================
      // 3. PROYECTOS
      // ========================================================

      const {
        data: projectsData,
        error: projectsError,
      } = await supabase
        .from("projects")
        .select(
  "id, nombre, company_id, client_id, user_id, estado"
)
        .order("nombre", {
          ascending: true,
        });

      if (projectsError) {
        console.error(
          "[EmployeeArea] Error loading projects:",
          projectsError
        );
      } else {
        setProjects(projectsData || []);
      }
      // ========================================================
      // CLIENTES PARA PRESUPUESTOS
      // ========================================================

      const {
        data: quotationClientsData,
        error: quotationClientsError,
      } = await supabase
        .from("clients")
        .select("*")
        .order("nombre", {
          ascending: true,
        });

      if (quotationClientsError) {
        console.error(
          "[EmployeeArea] Error loading quotation clients:",
          quotationClientsError
        );
      } else {
        setQuotationClients(
          quotationClientsData || []
        );
      }
      // ========================================================
      // 4. PRESUPUESTOS COMERCIALES
      // ========================================================
      // No usamos joins con clients/projects/companies: el worker
      // tiene acceso RLS directo a quotations y resolvemos empresa
      // y proyecto con los datos cargados arriba.
      const {
        data: quotationsData,
        error: quotationsError,
      } = await supabase
        .from("quotations")
        .select("*")
        .order("created_at", {
          ascending: false,
        });

      if (quotationsError) {
        console.error(
          "[EmployeeArea] Error loading quotations:",
          quotationsError
        );
      } else {
        setQuotations(quotationsData || []);
      }

      // ========================================================
      // 5. PERFILES / CLIENTES
      //
      // IMPORTANTE:
      // La empresa real se determina por company_id.
      // profiles.empresa NO se utiliza.
      // ========================================================

      const {
        data: profilesData,
        error: profilesError,
      } = await supabase
        .from("profiles")
        .select(
          `
            id,
            nombre,
            email,
            telefono,
            company_id,
            rol,
            fecha_registro,
            updated_at
          `
        )
        .order("nombre", {
          ascending: true,
        });

      if (profilesError) {
        console.error(
          "[EmployeeArea] Error loading profiles:",
          profilesError
        );
      } else {
        setProfiles(profilesData || []);
      }

      // ========================================================
      // 5. SOLICITUDES DE CAMBIO DE EMPRESA
      //
      // TABLA FUTURA:
      // company_change_requests
      //
      // Se añadirá en la próxima migración.
      // ========================================================

      const {
        data: changeRequests,
        error: changeRequestsError,
      } = await supabase
        .from("company_change_requests")
        .select(
          `
            id,
            user_id,
            current_company_id,
            requested_company_id,
            requested_company_name,
            status,
            created_at,
            reviewed_at,
            reviewed_by
          `
        )
        .order("created_at", {
          ascending: false,
        });

      if (changeRequestsError) {
        console.error(
          "[EmployeeArea] Error loading company change requests:",
          changeRequestsError
        );
      } else {
        setCompanyChangeRequests(
          changeRequests || []
        );
      }

      // ========================================================
      // 6. AUDITORÍAS
      // ========================================================

      const {
        data: audits,
        error: auditsError,
      } = await supabase
        .from("audit_requests")
        .select("*")
        .order("created_at", {
          ascending: false,
        });

      if (auditsError) {
        console.error(
          "[EmployeeArea] Error loading audits:",
          auditsError
        );
      } else {
        setAuditRequests(audits || []);
      }

      // ========================================================
      // 7. FACTURAS
      // ========================================================

      const {
        data: invs,
        error: invoicesError,
      } = await supabase
        .from("invoices")
        .select("*")
        .order("created_at", {
          ascending: false,
        });

      if (invoicesError) {
        console.error(
          "[EmployeeArea] Error loading invoices:",
          invoicesError
        );
      } else {
        setInvoices(invs || []);
      }

      // ========================================================
      // 8. TICKETS
      // ========================================================

      const {
        data: tks,
        error: ticketsError,
      } = await supabase
        .from("support_tickets")
        .select(`
          *,
          profiles:user_id (
            nombre,
            email
          )
        `)
        .order("created_at", {
          ascending: true,
        });

      if (ticketsError) {
        console.error(
          "[EmployeeArea] Error loading tickets:",
          ticketsError
        );
      } else {
        setTickets(tks || []);
      }

      // ========================================================
      // 9. CONVERSACIONES IA
      // ========================================================

      const {
        data: aiConversationsData,
        error: aiConversationsError,
      } = await supabase
        .from("ai_conversations")
        .select(`
          id,
          session_id,
          company_id,
          company_name,
          business_type,
          created_at,
          updated_at
        `)
        .order("updated_at", {
          ascending: false,
        });

      if (aiConversationsError) {
        console.error(
          "[EmployeeArea] Error loading AI conversations:",
          aiConversationsError
        );
      } else {
        setAiConversations(
          aiConversationsData || []
        );
      }
    } catch (error) {
      console.error(
        "[EmployeeArea] Error fetching data:",
        error
      );
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadData();
  }, [user]);

  // ============================================================
  // CREACIÓN / EDICIÓN DE PRESUPUESTOS
  // ============================================================
  const handleNewQuotation = () => {
    setEditingQuotation(null);
    setQuotationError("");
    setQuotationPdfFile(null);

    setQuotationForm({
      company_id: "",
      project_id: "",
      client_id: "",
      numero_presupuesto: "",
      titulo: "",
      descripcion_detallada: "",
      servicios_incluidos: [
        {
          descripcion: "",
          cantidad: 1,
          precio: 0,
        },
      ],
      precio_base: "",
      iva_porcentaje: "21",
      estado: "Pendiente",
      fecha_emision:
        getTodayForInput(),
      fecha_validez: "",
      notas: "",
    });

    setShowQuotationForm(true);
  };

  const addQuotationService = () => {
    setQuotationForm((current) => ({
      ...current,
      servicios_incluidos: [
        ...current.servicios_incluidos,
        {
          descripcion: "",
          cantidad: 1,
          precio: 0,
        },
      ],
    }));
  };

  const removeQuotationService = (
    index: number
  ) => {
    setQuotationForm((current) => ({
      ...current,
      servicios_incluidos:
        current.servicios_incluidos.filter(
          (_, serviceIndex) =>
            serviceIndex !== index
        ),
    }));
  };

  const updateQuotationService = (
    index: number,
    field: "descripcion" | "cantidad" | "precio",
    value: string
  ) => {
    setQuotationForm((current) => {
      const services = [
        ...current.servicios_incluidos,
      ];

      services[index] = {
        ...services[index],
        [field]:
          field === "descripcion"
            ? value
            : Number(value || 0),
      };

      const subtotal =
        calculateQuotationSubtotal(
          services
        );

      return {
        ...current,
        servicios_incluidos: services,
        precio_base:
          subtotal.toFixed(2),
      };
    });
  };
  const handleSaveQuotation = async () => {
    setQuotationError("");

    if (!quotationForm.company_id) {
      setQuotationError(
        "Selecciona una empresa."
      );
      return;
    }

    if (!quotationForm.project_id) {
      setQuotationError(
        "Selecciona un proyecto."
      );
      return;
    }

    if (!selectedQuotationProject) {
      setQuotationError(
        "El proyecto seleccionado no existe."
      );
      return;
    }

    if (
      String(selectedQuotationProject.company_id || "") !==
      String(quotationForm.company_id)
    ) {
      setQuotationError(
        "El proyecto no pertenece a la empresa seleccionada."
      );
      return;
    }

    if (!selectedQuotationProject.user_id) {
      setQuotationError(
        "El proyecto seleccionado no tiene un usuario asociado."
      );
      return;
    }

    if (!quotationForm.titulo.trim()) {
      setQuotationError(
        "Introduce un título para el presupuesto."
      );
      return;
    }

    const precioBase = Number(
      quotationForm.precio_base || 0
    );

    const iva = Number(
      quotationForm.iva_porcentaje || 0
    );

    if (
      !Number.isFinite(precioBase) ||
      precioBase < 0
    ) {
      setQuotationError(
        "El precio base no es válido."
      );
      return;
    }

    if (
      !Number.isFinite(iva) ||
      iva < 0
    ) {
      setQuotationError(
        "El porcentaje de IVA no es válido."
      );
      return;
    }

    if (
      editingQuotation &&
      !quotationForm.numero_presupuesto.trim()
    ) {
      setQuotationError(
        "El número de presupuesto es obligatorio al editar un presupuesto."
      );
      return;
    }

    try {
      setSavingQuotation(true);

      const payload = {
        company_id:
          quotationForm.company_id,

        user_id: user?.id,

        project_id:
          quotationForm.project_id ||
          null,

        client_id:
          selectedQuotationProject?.client_id ||
          null,

        ...(editingQuotation
          ? {
            numero_presupuesto:
              quotationForm.numero_presupuesto.trim(),
          }
          : {}),

        titulo:
          quotationForm.titulo.trim(),

        descripcion_detallada:
          quotationForm.descripcion_detallada.trim() ||
          null,

        servicios_incluidos:
          quotationForm.servicios_incluidos,

        precio_base: precioBase,

        iva_porcentaje: iva,

        precio_total:
          calculateQuotationTotal(
            precioBase,
            iva
          ),

        estado:
          quotationForm.estado,

        fecha_emision:
          quotationForm.fecha_emision
            ? new Date(
              `${quotationForm.fecha_emision}T00:00:00`
            ).toISOString()
            : new Date().toISOString(),

        fecha_validez:
          quotationForm.fecha_validez
            ? new Date(
              `${quotationForm.fecha_validez}T00:00:00`
            ).toISOString()
            : null,

        notas:
          quotationForm.notas.trim() ||
          null,

        updated_at:
          new Date().toISOString(),
      };

      let quotationId: string;
      let quotationNumber: string;

      if (editingQuotation) {
        const {
          data,
          error,
        } = await supabase
          .from("quotations")
          .update(payload)
          .eq(
            "id",
            editingQuotation.id
          )
          .select()
          .single();

        if (error) throw error;

        quotationId = data.id;
        quotationNumber = data.numero_presupuesto;
      } else {
        const {
          data,
          error,
        } = await supabase
          .from("quotations")
          .insert(payload)
          .select()
          .single();

        if (error) throw error;

        quotationId = data.id;
        quotationNumber = data.numero_presupuesto;
      }

      // ----------------------------------------------------------
      // PDF
      // ----------------------------------------------------------

      if (quotationPdfFile) {
        const path =
          `${quotationForm.company_id}/${quotationNumber}.pdf`;

        const {
          error: uploadError,
        } = await supabase.storage
          .from("quotations")
          .upload(
            path,
            quotationPdfFile,
            {
              upsert: true,
              contentType:
                "application/pdf",
            }
          );

        if (uploadError) {
          throw uploadError;
        }

        const {
          error: attachError,
        } = await supabase.rpc(
          "attach_quotation_document",
          {
            p_quotation_id:
              quotationId,
            p_document_path:
              path,
          }
        );

        if (attachError) {
          throw attachError;
        }
      }

      await loadData();

      setShowQuotationForm(false);
      setEditingQuotation(null);
      setQuotationPdfFile(null);

      alert(
        editingQuotation
          ? "Presupuesto actualizado correctamente."
          : "Presupuesto creado correctamente."
      );
    } catch (error: any) {
      console.error(
        "[EmployeeArea] Error saving quotation:",
        error
      );

      setQuotationError(
        error?.message ||
        "No se pudo guardar el presupuesto."
      );
    } finally {
      setSavingQuotation(false);
    }
  };
  // ============================================================
  // CREAR PROYECTO COMO WORKER
  // ============================================================

  const resetProjectForm = () => {
    setProjectForm({
      company_id: "",
      client_id: "",
      nombre: "",
      descripcion: "",
      fecha_inicio: "",
      fecha_fin: "",
    });
  };

  const handleNewProject = () => {
    setProjectError("");
    resetProjectForm();
    setShowCreateProject(true);
  };

  const handleEditQuotation = (
    quotation: any
  ) => {
    setEditingQuotation(
      quotation
    );

    setQuotationError("");
    setQuotationPdfFile(null);

    setQuotationForm({
      company_id:
        quotation.company_id || "",

      project_id:
        quotation.project_id || "",

      client_id:
        quotation.client_id || "",

      numero_presupuesto:
        quotation.numero_presupuesto || "",

      titulo:
        quotation.titulo || "",

      descripcion_detallada:
        quotation.descripcion_detallada || "",

      servicios_incluidos:
        Array.isArray(
          quotation.servicios_incluidos
        ) &&
          quotation.servicios_incluidos.length
          ? quotation.servicios_incluidos
          : [
            {
              descripcion: "",
              cantidad: 1,
              precio: 0,
            },
          ],

      precio_base:
        String(
          quotation.precio_base || 0
        ),

      iva_porcentaje:
        String(
          quotation.iva_porcentaje || 21
        ),

      estado:
        quotation.estado ||
        "Pendiente",

      fecha_emision:
        quotation.fecha_emision
          ? new Date(
            quotation.fecha_emision
          )
            .toISOString()
            .slice(0, 10)
          : getTodayForInput(),

      fecha_validez:
        quotation.fecha_validez
          ? new Date(
            quotation.fecha_validez
          )
            .toISOString()
            .slice(0, 10)
          : "",

      notas:
        quotation.notas || "",
    });

    setShowQuotationForm(true);
  };

  const handleDeleteQuotation = async (
    quotation: any
  ) => {
    const confirmed =
      window.confirm(
        `¿Seguro que quieres eliminar el presupuesto ${quotation.numero_presupuesto}?`
      );

    if (!confirmed) {
      return;
    }

    try {
      // Primero eliminamos el PDF si existe.
      if (quotation.document_path) {
        const {
          error: storageError,
        } = await supabase.storage
          .from("quotations")
          .remove([
            quotation.document_path,
          ]);

        if (storageError) {
          console.warn(
            "[EmployeeArea] No se pudo eliminar el PDF:",
            storageError
          );
        }
      }

      const {
        error,
      } = await supabase
        .from("quotations")
        .delete()
        .eq(
          "id",
          quotation.id
        );

      if (error) {
        throw error;
      }

      setQuotations(
        (current) =>
          current.filter(
            (item) =>
              item.id !== quotation.id
          )
      );

      alert(
        "Presupuesto eliminado correctamente."
      );
    } catch (error: any) {
      console.error(
        "[EmployeeArea] Error deleting quotation:",
        error
      );

      alert(
        error?.message ||
        "No se pudo eliminar el presupuesto."
      );
    }
  };



  // ============================================================
  // GESTIÓN DE PERFILES
  // ============================================================

  const filteredProfiles = profiles.filter((profile) => {
    const search = profileSearch
      .trim()
      .toLowerCase();

    if (!search) return true;

    const companyName =
      companies.find(
        (company) =>
          company.id === profile.company_id
      )?.company_name || "";

    return (
      profile.nombre
        ?.toLowerCase()
        .includes(search) ||
      profile.email
        ?.toLowerCase()
        .includes(search) ||
      companyName
        .toLowerCase()
        .includes(search)
    );
  });

  const getCompanyName = (
    companyId: string | null
  ) => {
    if (!companyId) {
      return "Sin empresa";
    }

    return (
      companies.find(
        (company) =>
          company.id === companyId
      )?.company_name ||
      "Empresa no encontrada"
    );
  };

  // ============================================================
  // FACTURAS — HELPERS DE PRESENTACIÓN
  // ============================================================

  const getInvoiceClientName = (invoice: any) => {
    const client = quotationClients.find(
      (item) => String(item.id) === String(invoice?.client_id)
    );

    if (client?.nombre) return client.nombre;

    const profile = profiles.find(
      (item) => String(item.id) === String(invoice?.user_id)
    );

    return profile?.nombre || "Sin cliente";
  };

  const getInvoiceTitle = (invoice: any) => {
    const description = String(invoice?.descripcion || "").trim();
    if (!description) return "Sin título";

    const titleLine = description
      .split("\n")
      .find((line) => line.toLowerCase().startsWith("título:"));

    if (titleLine) {
      return titleLine.slice("Título:".length).trim() || "Sin título";
    }

    return description.split("\n")[0].trim() || "Sin título";
  };

  const getInvoiceDescriptionPreview = (invoice: any) => {
    const description = String(invoice?.descripcion || "").trim();
    if (!description) return "";

    return description
      .split("\n")
      .filter((line) => !line.toLowerCase().startsWith("título:"))
      .join(" ")
      .replace(/\s+/g, " ")
      .trim();
  };

  const getInvoiceStatusBadge = (estado: string | null | undefined) => {
    const status = String(estado || "").toLowerCase();

    if (status === "pagada") {
      return (
        <Badge className="border-none bg-green-100 text-green-700 hover:bg-green-100">
          Pagada
        </Badge>
      );
    }

    if (status === "vencida") {
      return (
        <Badge className="border-none bg-red-100 text-red-700 hover:bg-red-100">
          Vencida
        </Badge>
      );
    }

    if (status === "cancelada") {
      return (
        <Badge className="border-none bg-gray-100 text-gray-700 hover:bg-gray-100">
          Cancelada
        </Badge>
      );
    }

    return (
      <Badge className="border-none bg-yellow-100 text-yellow-700 hover:bg-yellow-100">
        Pendiente
      </Badge>
    );
  };

  // ============================================================
  // ABRIR PERFIL
  // ============================================================

  const handleOpenProfile = (
    profile: any
  ) => {
    setSelectedProfile(profile);
    setSelectedProfileCompanyId(
      profile.company_id || ""
    );
  };

  // ============================================================
  // CAMBIAR EMPRESA DIRECTAMENTE
  //
  // IMPORTANTE:
  // NO hacemos UPDATE directo sobre profiles.company_id.
  //
  // La futura migración creará:
  //
  // admin_update_profile_company(
  //   p_user_id,
  //   p_company_id
  // )
  //
  // Esta RPC será la responsable de comprobar que
  // el usuario actual es un trabajador autorizado.
  // ============================================================

  const handleChangeProfileCompany =
    async () => {
      if (
        !selectedProfile ||
        !selectedProfileCompanyId
      ) {
        return;
      }

      if (
        selectedProfile.company_id ===
        selectedProfileCompanyId
      ) {
        return;
      }

      try {
        setSavingProfileCompany(true);

        const {
          error,
        } = await supabase.rpc(
          "admin_update_profile_company",
          {
            p_user_id:
              selectedProfile.id,
            p_company_id:
              selectedProfileCompanyId,
          }
        );

        if (error) {
          throw error;
        }

        setProfiles((current) =>
          current.map((profile) =>
            profile.id ===
              selectedProfile.id
              ? {
                ...profile,
                company_id:
                  selectedProfileCompanyId,
              }
              : profile
          )
        );

        setSelectedProfile(
          (current: any) =>
            current
              ? {
                ...current,
                company_id:
                  selectedProfileCompanyId,
              }
              : current
        );

        alert(
          "Empresa del cliente actualizada correctamente."
        );
      } catch (error: any) {
        console.error(
          "[EmployeeArea] Error changing profile company:",
          error
        );

        alert(
          error?.message ||
          "No se pudo cambiar la empresa del cliente."
        );
      } finally {
        setSavingProfileCompany(false);
      }
    };

  // ============================================================
  // APROBAR SOLICITUD DE CAMBIO
  //
  // FUTURA RPC:
  //
  // resolve_company_change_request(
  //   p_request_id,
  //   p_action
  // )
  //
  // p_action = 'approved' | 'rejected'
  //
  // La RPC realizará de forma atómica:
  //
  // 1. Validación del trabajador.
  // 2. Actualización de profiles.company_id.
  // 3. Actualización de la solicitud.
  // 4. reviewed_by.
  // 5. reviewed_at.
  // ============================================================

  const handleCompanyChangeRequest =
    async (
      requestId: string,
      action: "approved" | "rejected"
    ) => {
      try {
        setProcessingCompanyRequest(
          requestId
        );

        const {
          error,
        } = await supabase.rpc(
          "resolve_company_change_request",
          {
            p_request_id: requestId,
            p_action: action,
          }
        );

        if (error) {
          throw error;
        }

        setCompanyChangeRequests(
          (current) =>
            current.map((request) =>
              request.id === requestId
                ? {
                  ...request,
                  status: action,
                  reviewed_by:
                    user?.id || null,
                  reviewed_at:
                    new Date().toISOString(),
                }
                : request
            )
        );

        if (action === "approved") {
          alert(
            "Solicitud aprobada. La empresa del cliente ha sido actualizada."
          );
        } else {
          alert(
            "Solicitud rechazada correctamente."
          );
        }

        await loadData();
      } catch (error: any) {
        console.error(
          "[EmployeeArea] Error resolving company request:",
          error
        );

        alert(
          error?.message ||
          "No se pudo procesar la solicitud."
        );
      } finally {
        setProcessingCompanyRequest(
          null
        );
      }
    };

  
  // ============================================================
  // CREAR FACTURA
  // ============================================================

  const handleCreateInvoice = async () => {
    setInvoiceError("");
    if (!invoiceForm.company_id) return setInvoiceError("Selecciona una empresa.");
    if (!invoiceForm.project_id) return setInvoiceError("Selecciona un proyecto.");

    const selectedProject = projects.find((p) => String(p.id) === String(invoiceForm.project_id));
    if (!selectedProject) return setInvoiceError("El proyecto seleccionado no existe.");
    if (String(selectedProject.company_id || "") !== String(invoiceForm.company_id)) {
      return setInvoiceError("El proyecto no pertenece a la empresa seleccionada.");
    }
    if (!selectedProject.user_id) return setInvoiceError("El proyecto seleccionado no tiene un usuario asociado.");
    if (!invoiceForm.titulo.trim()) return setInvoiceError("Introduce un título para la factura.");

    const subtotal = Number(invoiceForm.precio_base || 0);
    const ivaPorcentaje = Number(invoiceForm.iva_porcentaje || 0);
    const irpfPorcentaje = Number(invoiceForm.irpf_porcentaje || 0);
    if (!Number.isFinite(subtotal) || subtotal < 0) return setInvoiceError("La base imponible no es válida.");
    if (!Number.isFinite(ivaPorcentaje) || ivaPorcentaje < 0 || ivaPorcentaje > 100) {
      return setInvoiceError("El porcentaje de IVA debe estar entre 0 y 100.");
    }
    if (invoiceForm.irpf_aplicado && (!Number.isFinite(irpfPorcentaje) || irpfPorcentaje <= 0 || irpfPorcentaje > 100)) {
      return setInvoiceError("El porcentaje de IRPF debe ser mayor que 0 y menor o igual que 100.");
    }

    const servicesText = invoiceForm.servicios_incluidos
      .filter((service) => String(service.descripcion || "").trim() || Number(service.cantidad || 0) !== 0 || Number(service.precio || 0) !== 0)
      .map((service) => `- ${String(service.descripcion || "Servicio").trim() || "Servicio"} | Cantidad: ${Number(service.cantidad || 0)} | Precio: ${Number(service.precio || 0).toFixed(2)} €`)
      .join("\n");

    const invoiceDescription = [
      `Título: ${invoiceForm.titulo.trim()}`,
      invoiceForm.descripcion_detallada.trim() ? `Descripción detallada: ${invoiceForm.descripcion_detallada.trim()}` : null,
      servicesText ? `Servicios incluidos:\n${servicesText}` : null,
      invoiceForm.notas.trim() ? `Notas: ${invoiceForm.notas.trim()}` : null,
    ].filter(Boolean).join("\n\n");

    setCreatingInvoice(true);
    try {
      const isEditing = Boolean(editingInvoice);
      let savedInvoice: any;

      if (isEditing) {
        const { data, error } = await supabase.rpc("update_invoice_by_worker", {
          p_invoice_id: editingInvoice.id,
          p_company_id: invoiceForm.company_id,
          p_project_id: invoiceForm.project_id,
          p_fecha_emision: invoiceForm.fecha_emision ? new Date(`${invoiceForm.fecha_emision}T00:00:00`).toISOString() : null,
          p_fecha_vencimiento: invoiceForm.fecha_vencimiento ? new Date(`${invoiceForm.fecha_vencimiento}T00:00:00`).toISOString() : null,
          p_descripcion: invoiceDescription || null,
          p_subtotal: subtotal,
          p_iva_aplicado: ivaPorcentaje > 0,
          p_iva_porcentaje: ivaPorcentaje,
          p_irpf_aplicado: Boolean(invoiceForm.irpf_aplicado),
          p_irpf_porcentaje: invoiceForm.irpf_aplicado ? irpfPorcentaje : 0,
          p_estado: invoiceForm.estado || "pendiente",
        });
        if (error) throw error;
        savedInvoice = Array.isArray(data) ? data[0] : data;
      } else {
        const { data, error } = await supabase.rpc("create_invoice_by_worker", {
          p_company_id: invoiceForm.company_id,
          p_project_id: invoiceForm.project_id,
          p_fecha_emision: invoiceForm.fecha_emision ? new Date(`${invoiceForm.fecha_emision}T00:00:00`).toISOString() : null,
          p_fecha_vencimiento: invoiceForm.fecha_vencimiento ? new Date(`${invoiceForm.fecha_vencimiento}T00:00:00`).toISOString() : null,
          p_descripcion: invoiceDescription || null,
          p_subtotal: subtotal,
          p_iva_porcentaje: ivaPorcentaje,
        });
        if (error) throw error;
        savedInvoice = Array.isArray(data) ? data[0] : data;
      }

      if (!savedInvoice?.id || !savedInvoice.numero_factura) throw new Error("No se pudo guardar correctamente la factura.");
      const invoiceNumber = savedInvoice.numero_factura;
      setGeneratedInvoiceNumber(invoiceNumber);

      if (invoicePdfFile) {
        const pdfPath = `${invoiceNumber}.pdf`;
        const { error: uploadError } = await supabase.storage.from("invoices").upload(pdfPath, invoicePdfFile, {
          cacheControl: "3600", upsert: true, contentType: "application/pdf",
        });
        if (uploadError) throw new Error(`No se pudo subir el PDF: ${uploadError.message}`);
        const { error: attachError } = await supabase.rpc("attach_invoice_document", {
          p_invoice_id: savedInvoice.id, p_document_path: pdfPath,
        });
        if (attachError) throw new Error(`No se pudo asociar el PDF: ${attachError.message}`);
      }

      await loadData();
      alert(isEditing ? `Factura ${invoiceNumber} actualizada correctamente.` : `Factura ${invoiceNumber} creada correctamente.`);
      setShowCreateInvoice(false);
      setEditingInvoice(null);
      setInvoicePdfFile(null);
      setGeneratedInvoiceNumber("");
      setInvoiceError("");
      setInvoiceForm({
        company_id: "", project_id: "", user_id: "", numero_factura: "", titulo: "", descripcion_detallada: "",
        servicios_incluidos: [{ descripcion: "", cantidad: 1, precio: 0 }], precio_base: "", iva_porcentaje: "21",
        irpf_aplicado: false, irpf_porcentaje: "0", estado: "pendiente", fecha_emision: "", fecha_vencimiento: "", notas: "",
      });
    } catch (error: any) {
      console.error("[EmployeeArea] Error saving invoice:", error);
      setInvoiceError(error?.message || "No se pudo guardar la factura.");
    } finally {
      setCreatingInvoice(false);
    }
  };
  // ============================================================
  // CONVERSACIÓN IA
  // ============================================================

  const handleOpenAIConversation =
    async (
      conversation: any
    ) => {
      setSelectedAIConversation(
        conversation
      );

      setAiMessages([]);

      setLoadingAIConversation(
        true
      );

      try {
        const {
          data,
          error,
        } = await supabase
          .from("ai_messages")
          .select(`
            id,
            conversation_id,
            role,
            content,
            created_at
          `)
          .eq(
            "conversation_id",
            conversation.id
          )
          .order("created_at", {
            ascending: true,
          });

        if (error) {
          throw error;
        }

        setAiMessages(data || []);
      } catch (error) {
        console.error(
          "[EmployeeArea] Error loading AI conversation:",
          error
        );
      } finally {
        setLoadingAIConversation(
          false
        );
      }
    };

  // ============================================================
  // LOGOUT
  // ============================================================

  // ============================================================
  // FACTURAS — ACCIONES
  // ============================================================

  const parseInvoiceDescription = (description: string | null | undefined) => {
    const text = String(description || "").trim();
    const lines = text.split("\n");
    const titleLine = lines.find((line) => line.toLowerCase().startsWith("título:"));
    const descriptionLine = lines.find((line) => line.toLowerCase().startsWith("descripción detallada:"));
    const notesLine = lines.find((line) => line.toLowerCase().startsWith("notas:"));
    const services = lines.flatMap((line) => {
      const m = line.match(/^-\s*(.*?)\s*\|\s*Cantidad:\s*([0-9.,]+)\s*\|\s*Precio:\s*([0-9.,]+)\s*€/i);
      if (!m) return [];
      const n = (v: string) => Number(v.replace(/\./g, "").replace(",", "."));
      return [{ descripcion: m[1].trim(), cantidad: n(m[2]) || 0, precio: n(m[3]) || 0 }];
    });
    return {
      title: titleLine ? titleLine.slice(7).trim() : lines[0] || "",
      descriptionDetail: descriptionLine ? descriptionLine.slice("Descripción detallada:".length).trim() : "",
      notes: notesLine ? notesLine.slice("Notas:".length).trim() : "",
      services: services.length ? services : [{ descripcion: "", cantidad: 1, precio: 0 }],
    };
  };

  const handleViewInvoice = (invoice: any) => setSelectedInvoice(invoice);

  const handleEditInvoice = (invoice: any) => {
    const parsed = parseInvoiceDescription(invoice.descripcion);
    setSelectedInvoice(null);
    setEditingInvoice(invoice);
    setInvoiceError("");
    setInvoicePdfFile(null);
    setGeneratedInvoiceNumber(invoice.numero_factura || "");
    setInvoiceForm({
      company_id: invoice.company_id || "",
      project_id: invoice.project_id || "",
      user_id: invoice.user_id || "",
      numero_factura: invoice.numero_factura || "",
      titulo: parsed.title,
      descripcion_detallada: parsed.descriptionDetail,
      servicios_incluidos: parsed.services,
      precio_base: String(invoice.subtotal ?? Math.max(Number(invoice.monto || 0) - Number(invoice.iva_importe || 0), 0)),
      iva_porcentaje: String(invoice.iva_porcentaje ?? 0),
      irpf_aplicado: Boolean(invoice.irpf_aplicado),
      irpf_porcentaje: String(invoice.irpf_porcentaje ?? 0),
      estado: String(invoice.estado || "pendiente").toLowerCase(),
      fecha_emision: invoice.fecha_emision ? new Date(invoice.fecha_emision).toISOString().slice(0, 10) : getTodayForInput(),
      fecha_vencimiento: invoice.fecha_vencimiento ? new Date(invoice.fecha_vencimiento).toISOString().slice(0, 10) : "",
      notas: parsed.notes,
    });
    setShowCreateInvoice(true);
  };

  const handleOpenInvoicePdf = async (invoice: any) => {
    if (!invoice.document_path) return alert("Esta factura todavía no tiene un PDF adjunto.");
    try {
      setOpeningInvoicePdf(invoice.id);
      const { data, error } = await supabase.storage.from("invoices").createSignedUrl(invoice.document_path, 300);
      if (error) throw error;
      if (!data?.signedUrl) throw new Error("No se pudo generar el enlace seguro del PDF.");
      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (error: any) {
      console.error("[EmployeeArea] Error opening invoice PDF:", error);
      alert(error?.message || "No se pudo abrir el PDF de la factura.");
    } finally { setOpeningInvoicePdf(null); }
  };

  const handleDownloadInvoicePdf = async (invoice: any) => {
    if (!invoice.document_path) return alert("Esta factura todavía no tiene un PDF adjunto.");
    try {
      setOpeningInvoicePdf(invoice.id);
      const { data, error } = await supabase.storage.from("invoices").createSignedUrl(invoice.document_path, 300, { download: `${invoice.numero_factura}.pdf` });
      if (error) throw error;
      if (!data?.signedUrl) throw new Error("No se pudo generar el enlace seguro del PDF.");
      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (error: any) {
      console.error("[EmployeeArea] Error downloading invoice PDF:", error);
      alert(error?.message || "No se pudo descargar el PDF de la factura.");
    } finally { setOpeningInvoicePdf(null); }
  };

  const handleDeleteInvoice = async (invoice: any) => {
    if (!window.confirm(`¿Seguro que quieres eliminar la factura ${invoice.numero_factura}? Esta acción también eliminará su PDF asociado.`)) return;
    try {
      setDeletingInvoice(invoice.id);
      const { data, error } = await supabase.rpc("delete_invoice_by_worker", { p_invoice_id: invoice.id });
      if (error) throw error;
      if (!data) throw new Error("La factura no se pudo eliminar correctamente.");
      setInvoices((current) => current.filter((item) => item.id !== invoice.id));
      if (selectedInvoice?.id === invoice.id) setSelectedInvoice(null);
      alert("Factura eliminada correctamente.");
    } catch (error: any) {
      console.error("[EmployeeArea] Error deleting invoice:", error);
      alert(error?.message || "No se pudo eliminar la factura.");
    } finally { setDeletingInvoice(null); }
  };

  // ============================================================
  // PRESUPUESTOS — PDF
  // ============================================================

  const handleOpenQuotationPdf = async (quotation: any) => {
    if (!quotation.document_path) {
      alert("Este presupuesto todavía no tiene un PDF adjunto.");
      return;
    }

    try {
      setOpeningQuotationPdf(quotation.id);

      const { data, error } = await supabase.storage
        .from("quotations")
        .createSignedUrl(quotation.document_path, 300);

      if (error) throw error;

      if (!data?.signedUrl) {
        throw new Error("No se pudo generar el enlace seguro del PDF.");
      }

      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (error: any) {
      console.error(
        "[EmployeeArea] Error opening quotation PDF:",
        error
      );
      alert(
        error?.message ||
        "No se pudo abrir el PDF del presupuesto."
      );
    } finally {
      setOpeningQuotationPdf(null);
    }
  };

  const handleDownloadQuotationPdf = async (quotation: any) => {
    if (!quotation.document_path) {
      alert("Este presupuesto todavía no tiene un PDF adjunto.");
      return;
    }

    try {
      setOpeningQuotationPdf(quotation.id);

      const { data, error } = await supabase.storage
        .from("quotations")
        .createSignedUrl(quotation.document_path, 300, {
          download: `${quotation.numero_presupuesto}.pdf`,
        });

      if (error) throw error;

      if (!data?.signedUrl) {
        throw new Error("No se pudo generar el enlace seguro del PDF.");
      }

      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (error: any) {
      console.error(
        "[EmployeeArea] Error downloading quotation PDF:",
        error
      );
      alert(
        error?.message ||
        "No se pudo descargar el PDF del presupuesto."
      );
    } finally {
      setOpeningQuotationPdf(null);
    }
  };

  const handleUploadQuotationPdf = async (
    quotation: any,
    file: File
  ) => {
    if (!file) return;

    if (
      file.type !== "application/pdf" &&
      !file.name.toLowerCase().endsWith(".pdf")
    ) {
      alert("Solo se permiten archivos PDF.");
      return;
    }

    if (file.size > 10 * 1024 * 1024) {
      alert("El PDF no puede superar los 10 MB.");
      return;
    }

    try {
      setUploadingQuotationPdf(quotation.id);

      const path = `${quotation.company_id}/${quotation.numero_presupuesto}.pdf`;

      const { error: uploadError } = await supabase.storage
        .from("quotations")
        .upload(path, file, {
          upsert: true,
          contentType: "application/pdf",
        });

      if (uploadError) throw uploadError;

      const { error: attachError } = await supabase.rpc(
        "attach_quotation_document",
        {
          p_quotation_id: quotation.id,
          p_document_path: path,
        }
      );

      if (attachError) throw attachError;

      setQuotations((current) =>
        current.map((item) =>
          item.id === quotation.id
            ? { ...item, document_path: path }
            : item
        )
      );

      alert("PDF del presupuesto adjuntado correctamente.");
    } catch (error: any) {
      console.error(
        "[EmployeeArea] Error uploading quotation PDF:",
        error
      );
      alert(
        error?.message ||
        "No se pudo adjuntar el PDF del presupuesto."
      );
    } finally {
      setUploadingQuotationPdf(null);
    }
  };
  // ============================================================
  // PRESUPUESTOS — HELPERS
  // ============================================================

  const getTodayForInput = () => {
    return new Date().toISOString().slice(0, 10);
  };

  const calculateQuotationSubtotal = (
    services: any[]
  ) => {
    return services.reduce(
      (total, service) =>
        total +
        Number(service.cantidad || 0) *
        Number(service.precio || 0),
      0
    );
  };

  const calculateQuotationTotal = (
    precioBase: number,
    iva: number
  ) => {
    return (
      precioBase +
      precioBase * (iva / 100)
    );
  };

  // Valores calculados del formulario de presupuesto.
  // Se declaran después de los helpers para evitar usar
  // calculateQuotationTotal antes de su inicialización.
  const quotationBase = Number(quotationForm.precio_base || 0);
  const quotationIva = Number(quotationForm.iva_porcentaje || 0);
  const quotationTotal =
    quotationBase + quotationBase * (quotationIva / 100);

  // ============================================================
  // RELACIÓN PROYECTO -> EMPRESA
  // ============================================================
  // La relación principal es projects.company_id.
  //
  // Para no perder proyectos antiguos o proyectos creados antes
  // de que quedase correctamente asociada la empresa, utilizamos
  // dos respaldos:
  //   1. projects.client_id -> clients.company_id
  //   2. projects.user_id   -> profiles.company_id
  //
  // Esto NO modifica la BD ni cambia ninguna relación existente.
  // Solo permite que EmployeeArea determine correctamente la
  // empresa a la que pertenece un proyecto para mostrarlo en
  // presupuestos y facturas.
  const quotationProjects = quotationForm.company_id
    ? projects.filter(
      (project) =>
        String(project?.company_id || "") ===
        String(quotationForm.company_id)
    )
    : [];

  const quotationClientsForCompany =
    quotationForm.company_id
      ? quotationClients.filter(
        (client) =>
          String(client.company_id || "") ===
          String(quotationForm.company_id)
      )
      : [];

  const selectedQuotationProject = projects.find(
    (project) =>
      String(project.id) === String(quotationForm.project_id)
  );

  const selectedQuotationUser = selectedQuotationProject?.user_id
    ? profiles.find(
      (profile) =>
        String(profile.id) ===
        String(selectedQuotationProject.user_id)
    )
    : null;

  const getQuotationStatusBadge = (
    estado: string | null | undefined
  ) => {
    const status = String(estado || "").toLowerCase();

    if (status === "aceptado") {
      return (
        <Badge className="border-none bg-green-100 text-green-700 hover:bg-green-100">
          Aceptado
        </Badge>
      );
    }
    if (status === "rechazado") {
      return (
        <Badge className="border-none bg-red-100 text-red-700 hover:bg-red-100">
          Rechazado
        </Badge>
      );
    }

    return (
      <Badge className="border-none bg-yellow-100 text-yellow-700 hover:bg-yellow-100">
        Pendiente
      </Badge>
    );
  };

  // ============================================================
  // LOGOUT
  // ============================================================

  const handleLogout =
    async () => {
      await signOut();
      setLocation("/");
    };

  // ============================================================
  // FECHAS
  // ============================================================

  const formatDate = (
    dateString: string
  ) => {
    try {
      return format(
        new Date(dateString),
        "dd MMM yyyy HH:mm",
        {
          locale: es,
        }
      );
    } catch {
      return dateString;
    }
  };

  // ============================================================
  // LOADING
  // ============================================================

  if (loading) {
    return (
      <div className="min-h-screen bg-[#F5F7FA]">
        <EmployeeAreaHeader
          userName="Trabajador"
          onLogout={handleLogout}
        />

        <div className="flex min-h-[60vh] items-center justify-center">
          <RefreshCw className="h-10 w-10 animate-spin text-[#1E3A8A]" />
        </div>
      </div>
    );
  }

  // ============================================================
  // RENDER
  // ============================================================

  return (
    <div className="min-h-screen bg-[#F5F7FA]">

      <EmployeeAreaHeader
        userName={
          workerName ||
          "Trabajador"
        }
        onLogout={handleLogout}
      />

      <main className="container mx-auto px-4 py-8">

        {/* ======================================================
    NAVEGACIÓN
    ====================================================== */}
        {/* ======================================================
    NAVEGACIÓN
    ====================================================== */}

        <div className="mb-10 overflow-hidden rounded-xl border border-[#E4E8EF] bg-white shadow-sm">
          <div className="flex h-24 items-end gap-1 overflow-x-auto px-3">

            <button
              type="button"
              onClick={() => setActiveTab("projects")}
              className={`flex h-20 shrink-0 items-end justify-center gap-2 px-4 pb-3 text-sm font-semibold whitespace-nowrap border-b-2 ${activeTab === "projects"
                  ? "border-[#1E3A8A] text-[#1E3A8A]"
                  : "border-transparent text-gray-500 hover:text-[#1E3A8A]"
                }`}
            >
              <FileText className="h-5 w-5" />
              Proyectos
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("clients")}
              className={`flex h-20 shrink-0 items-end justify-center gap-2 px-4 pb-3 text-sm font-semibold whitespace-nowrap border-b-2 ${activeTab === "clients"
                  ? "border-[#1E3A8A] text-[#1E3A8A]"
                  : "border-transparent text-gray-500 hover:text-[#1E3A8A]"
                }`}
            >
              <Users className="h-5 w-5" />
              Clientes

              {companyChangeRequests.filter(
                (request) => request.status === "pending"
              ).length > 0 && (
                  <Badge className="bg-red-600 text-white hover:bg-red-600">
                    {
                      companyChangeRequests.filter(
                        (request) => request.status === "pending"
                      ).length
                    }
                  </Badge>
                )}
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("quotations")}
              className={`flex h-20 shrink-0 items-end justify-center gap-2 px-4 pb-3 text-sm font-semibold whitespace-nowrap border-b-2 ${activeTab === "quotations"
                  ? "border-[#1E3A8A] text-[#1E3A8A]"
                  : "border-transparent text-gray-500 hover:text-[#1E3A8A]"
                }`}
            >
              <FileText className="h-5 w-5" />
              Presupuestos
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("billing")}
              className={`flex h-20 shrink-0 items-end justify-center gap-2 px-4 pb-3 text-sm font-semibold whitespace-nowrap border-b-2 ${activeTab === "billing"
                  ? "border-[#1E3A8A] text-[#1E3A8A]"
                  : "border-transparent text-gray-500 hover:text-[#1E3A8A]"
                }`}
            >
              <FileText className="h-5 w-5" />
              Facturación
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("audits")}
              className={`flex h-20 shrink-0 items-end justify-center gap-2 px-4 pb-3 text-sm font-semibold whitespace-nowrap border-b-2 ${activeTab === "audits"
                  ? "border-[#1E3A8A] text-[#1E3A8A]"
                  : "border-transparent text-gray-500 hover:text-[#1E3A8A]"
                }`}
            >
              <FileText className="h-5 w-5" />
              Auditorías
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("tickets")}
              className={`flex h-20 shrink-0 items-end justify-center gap-2 px-4 pb-3 text-sm font-semibold whitespace-nowrap border-b-2 ${activeTab === "tickets"
                  ? "border-[#1E3A8A] text-[#1E3A8A]"
                  : "border-transparent text-gray-500 hover:text-[#1E3A8A]"
                }`}
            >
              <FileText className="h-5 w-5" />
              Tickets
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("ai")}
              className={`flex h-20 shrink-0 items-end justify-center gap-2 px-4 pb-3 text-sm font-semibold whitespace-nowrap border-b-2 ${activeTab === "ai"
                  ? "border-[#1E3A8A] text-[#1E3A8A]"
                  : "border-transparent text-gray-500 hover:text-[#1E3A8A]"
                }`}
            >
              <FileText className="h-5 w-5" />
              Conversaciones IA
            </button>

          </div>
        </div>
        {/* ======================================================
            PROYECTOS
            ====================================================== */}

        <div
          hidden={
            activeTab !==
            "projects"
          }
        >
          <EmployeeProjects
            key={projectsRefreshKey}
            onCreateProject={handleNewProject}
          />
        </div>
{/* ============================================================
    HITOS — PANEL PROVISIONAL DE PRUEBA
    ============================================================ */}

<div className="mt-8 rounded-lg border border-orange-300 bg-orange-50 p-6">

  <h2 className="mb-2 text-lg font-bold text-orange-800">
    PRUEBA PROVISIONAL — Gestión de hitos
  </h2>

  <p className="mb-6 text-sm text-orange-700">
    Panel temporal para crear hitos y modificar su progreso.
  </p>

  {/* --------------------------------------------------------
      SELECCIONAR PROYECTO
      -------------------------------------------------------- */}

  <div className="mb-6">

    <label className="mb-2 block text-sm font-semibold">
      Proyecto
    </label>

    <select
      value={selectedMilestoneProjectId}
      onChange={async (event) => {
        const projectId = event.target.value;

        setSelectedMilestoneProjectId(projectId);

        await loadProjectMilestones(projectId);
      }}
      className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm"
    >

      <option value="">
        Selecciona un proyecto
      </option>

      {projects.map((project) => (
        <option
          key={project.id}
          value={project.id}
        >
          {project.nombre}
        </option>
      ))}

    </select>

  </div>

  {selectedMilestoneProjectId && (
    <>

      {/* ------------------------------------------------------
          PROGRESO
          ------------------------------------------------------ */}

      <div className="mb-6 rounded-md border border-gray-200 bg-white p-4">

        <div className="mb-2 flex items-center justify-between">

          <span className="font-semibold">
            Progreso
          </span>

          <span className="font-bold text-[#1E3A8A]">
            {projectProgress?.progress_percentage ?? 0}%
          </span>

        </div>

        <div className="mb-2 h-3 overflow-hidden rounded-full bg-gray-200">

          <div
            className="h-full bg-green-500 transition-all"
            style={{
              width: `${projectProgress?.progress_percentage ?? 0}%`,
            }}
          />

        </div>

        <p className="text-xs text-gray-500">

          {projectProgress?.completed_milestones ?? 0}
          {" / "}
          {projectProgress?.total_milestones ?? 0}
          {" hitos completados"}

        </p>

      </div>

      {/* ------------------------------------------------------
          CREAR HITO
          ------------------------------------------------------ */}

      <div className="mb-6 rounded-md border border-gray-200 bg-white p-4">

        <h3 className="mb-4 font-semibold">
          Crear nuevo hito
        </h3>

        <div className="space-y-3">

          <input
            type="text"
            value={milestoneForm.nombre}
            onChange={(event) =>
              setMilestoneForm((current) => ({
                ...current,
                nombre: event.target.value,
              }))
            }
            placeholder="Nombre del hito"
            maxLength={200}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />

          <textarea
            value={milestoneForm.descripcion}
            onChange={(event) =>
              setMilestoneForm((current) => ({
                ...current,
                descripcion: event.target.value,
              }))
            }
            placeholder="Descripción (opcional)"
            maxLength={2000}
            rows={3}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
          />

          <div>

            <label className="mb-1 block text-xs font-semibold text-gray-600">
              Fecha prevista
            </label>

            <input
              type="datetime-local"
              value={milestoneForm.fecha_prevista}
              onChange={(event) =>
                setMilestoneForm((current) => ({
                  ...current,
                  fecha_prevista: event.target.value,
                }))
              }
              className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
            />

          </div>

          <button
            type="button"
            onClick={handleCreateMilestone}
            disabled={creatingMilestone}
            className="rounded-md bg-[#1E3A8A] px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
          >
            {creatingMilestone
              ? "Creando..."
              : "Crear hito"}
          </button>

        </div>

      </div>

      {/* ------------------------------------------------------
          LISTADO DE HITOS
          ------------------------------------------------------ */}

      <div className="rounded-md border border-gray-200 bg-white p-4">

        <div className="mb-4 flex items-center justify-between">

          <h3 className="font-semibold">
            Hitos del proyecto
          </h3>

          <button
            type="button"
            onClick={() =>
              loadProjectMilestones(
                selectedMilestoneProjectId
              )
            }
            className="text-xs font-semibold text-[#1E3A8A] underline"
          >
            Recargar
          </button>

        </div>

        {loadingMilestones ? (

          <p className="text-sm text-gray-500">
            Cargando hitos...
          </p>

        ) : projectMilestones.length === 0 ? (

          <p className="text-sm text-gray-500">
            Este proyecto todavía no tiene hitos.
          </p>

        ) : (

          <div className="space-y-3">

            {projectMilestones.map(
              (milestone, index) => (

                <div
                  key={milestone.id}
                  className="rounded-md border border-gray-200 p-4"
                >

                  <div className="mb-3 flex items-start justify-between gap-4">

                    <div>

                      <p className="font-semibold">
                        {index + 1}. {milestone.nombre}
                      </p>

                      {milestone.descripcion && (
                        <p className="mt-1 text-sm text-gray-500">
                          {milestone.descripcion}
                        </p>
                      )}

                      <p className="mt-2 text-xs text-gray-400">
                        Fecha prevista:{" "}
                        {new Date(
                          milestone.fecha_prevista
                        ).toLocaleString("es-ES")}
                      </p>

                    </div>

                    <span className="text-xs font-semibold">
                      {milestone.estado}
                    </span>

                  </div>

                  <div className="flex flex-wrap gap-2">

                    <button
                      type="button"
                      onClick={() =>
                        handleChangeMilestoneStatus(
                          milestone.id,
                          "pendiente"
                        )
                      }
                      className="rounded border border-gray-300 bg-white px-3 py-1.5 text-xs"
                    >
                      Pendiente
                    </button>

                    <button
                      type="button"
                      onClick={() =>
                        handleChangeMilestoneStatus(
                          milestone.id,
                          "en_curso"
                        )
                      }
                      className="rounded border border-blue-300 bg-blue-50 px-3 py-1.5 text-xs text-blue-700"
                    >
                      En curso
                    </button>

                    <button
                      type="button"
                      onClick={() =>
                        handleChangeMilestoneStatus(
                          milestone.id,
                          "completado"
                        )
                      }
                      className="rounded border border-green-300 bg-green-50 px-3 py-1.5 text-xs text-green-700"
                    >
                      Completado
                    </button>

                  </div>

                </div>

              )
            )}

          </div>

        )}

      </div>

    </>
  )}

</div>
        {/* ======================================================
            CLIENTES / PERFILES
            ====================================================== */}

        <div
          hidden={
            activeTab !==
            "clients"
          }
        >
          <section className="space-y-8">

            <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">

              <div>
                <h2 className="text-2xl font-bold text-[#1E3A8A]">
                  Gestión de clientes
                </h2>

                <p className="mt-1 text-sm text-gray-500">
                  Gestiona los perfiles de los clientes y sus empresas asociadas.
                </p>
              </div>

              <Badge
                variant="outline"
                className="w-fit bg-white"
              >
                {profiles.length} clientes
              </Badge>

            </div>

            {/* SOLICITUDES */}

            <Card className="overflow-hidden border-none shadow-md">

              <div className="border-b bg-white px-6 py-5">

                <div className="flex items-center justify-between">

                  <div>
                    <h3 className="flex items-center gap-2 text-lg font-bold text-[#1E3A8A]">
                      <ClipboardList className="h-5 w-5" />
                      Solicitudes de cambio de empresa
                    </h3>

                    <p className="mt-1 text-sm text-gray-500">
                      Revisa y gestiona las solicitudes enviadas por los clientes.
                    </p>
                  </div>

                  <Badge variant="outline">
                    {
                      companyChangeRequests.filter(
                        (request) =>
                          request.status ===
                          "pending"
                      ).length
                    }{" "}
                    pendientes
                  </Badge>

                </div>

              </div>

              <div className="overflow-x-auto">

                <Table>

                  <TableHeader className="bg-gray-50">

                    <TableRow>

                      <TableHead className="font-bold">
                        Cliente
                      </TableHead>

                      <TableHead className="font-bold">
                        Empresa actual
                      </TableHead>

                      <TableHead className="font-bold">
                        Empresa solicitada
                      </TableHead>

                      <TableHead className="font-bold">
                        Fecha
                      </TableHead>

                      <TableHead className="font-bold">
                        Estado
                      </TableHead>

                      <TableHead className="text-center font-bold">
                        Acción
                      </TableHead>

                    </TableRow>

                  </TableHeader>

                  <TableBody>

                    {companyChangeRequests.length ===
                      0 ? (

                      <TableRow>

                        <TableCell
                          colSpan={6}
                          className="py-10 text-center text-gray-500"
                        >
                          No hay solicitudes de cambio de empresa.
                        </TableCell>

                      </TableRow>

                    ) : (

                      companyChangeRequests.map(
                        (request) => {

                          const requestProfile =
                            profiles.find(
                              (profile) =>
                                profile.id ===
                                request.user_id
                            );

                          return (
                            <TableRow
                              key={
                                request.id
                              }
                            >

                              <TableCell>

                                <div className="font-medium">
                                  {
                                    requestProfile?.nombre ||
                                    "Cliente"
                                  }
                                </div>

                                <div className="text-xs text-gray-500">
                                  {
                                    requestProfile?.email ||
                                    ""
                                  }
                                </div>

                              </TableCell>

                              <TableCell>
                                {getCompanyName(
                                  request.current_company_id
                                )}
                              </TableCell>

                              <TableCell>

                                <div className="font-medium">
                                  {request.requested_company_id
                                    ? getCompanyName(
                                      request.requested_company_id
                                    )
                                    : request.requested_company_name ||
                                    "Sin especificar"}
                                </div>

                              </TableCell>

                              <TableCell className="text-sm text-gray-500">
                                {formatDate(
                                  request.created_at
                                )}
                              </TableCell>

                              <TableCell>

                                <Badge
                                  className={
                                    request.status ===
                                      "approved"
                                      ? "bg-green-100 text-green-800 hover:bg-green-100"
                                      : request.status ===
                                        "rejected"
                                        ? "bg-red-100 text-red-800 hover:bg-red-100"
                                        : "bg-yellow-100 text-yellow-800 hover:bg-yellow-100"
                                  }
                                >
                                  {request.status ===
                                    "approved"
                                    ? "Aprobada"
                                    : request.status ===
                                      "rejected"
                                      ? "Rechazada"
                                      : "Pendiente"}
                                </Badge>

                              </TableCell>

                              <TableCell>

                                {request.status ===
                                  "pending" ? (

                                  <div className="flex justify-center gap-2">

                                    <button
                                      type="button"
                                      disabled={
                                        processingCompanyRequest ===
                                        request.id
                                      }
                                      onClick={() =>
                                        handleCompanyChangeRequest(
                                          request.id,
                                          "approved"
                                        )
                                      }
                                      className="inline-flex items-center gap-1 rounded-lg bg-green-600 px-3 py-2 text-xs font-semibold text-white hover:bg-green-700 disabled:opacity-50"
                                    >
                                      <Check className="h-4 w-4" />
                                      Aprobar
                                    </button>

                                    <button
                                      type="button"
                                      disabled={
                                        processingCompanyRequest ===
                                        request.id
                                      }
                                      onClick={() =>
                                        handleCompanyChangeRequest(
                                          request.id,
                                          "rejected"
                                        )
                                      }
                                      className="inline-flex items-center gap-1 rounded-lg bg-red-600 px-3 py-2 text-xs font-semibold text-white hover:bg-red-700 disabled:opacity-50"
                                    >
                                      <X className="h-4 w-4" />
                                      Rechazar
                                    </button>

                                  </div>

                                ) : (

                                  <span className="text-xs text-gray-400">
                                    Gestionada
                                  </span>

                                )}

                              </TableCell>

                            </TableRow>
                          );
                        }
                      )

                    )}

                  </TableBody>

                </Table>

              </div>

            </Card>

            {/* LISTADO DE CLIENTES */}

            <Card className="overflow-hidden border-none shadow-md">

              <div className="border-b bg-white px-6 py-5">

                <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">

                  <div>
                    <h3 className="flex items-center gap-2 text-lg font-bold text-[#1E3A8A]">
                      <UserCog className="h-5 w-5" />
                      Perfiles de clientes
                    </h3>

                    <p className="mt-1 text-sm text-gray-500">
                      Consulta y modifica la empresa asociada a cada cliente.
                    </p>
                  </div>

                  <div className="relative w-full md:w-80">

                    <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />

                    <Input
                      value={
                        profileSearch
                      }
                      onChange={(event) =>
                        setProfileSearch(
                          event.target.value
                        )
                      }
                      placeholder="Buscar cliente o empresa..."
                      className="pl-9"
                    />

                  </div>

                </div>

              </div>

              <div className="overflow-x-auto">

                <Table>

                  <TableHeader className="bg-gray-50">

                    <TableRow>

                      <TableHead className="font-bold">
                        Cliente
                      </TableHead>

                      <TableHead className="font-bold">
                        Teléfono
                      </TableHead>

                      <TableHead className="font-bold">
                        Empresa
                      </TableHead>

                      <TableHead className="font-bold">
                        Registro
                      </TableHead>

                      <TableHead className="text-center font-bold">
                        Acción
                      </TableHead>

                    </TableRow>

                  </TableHeader>

                  <TableBody>

                    {filteredProfiles.length ===
                      0 ? (

                      <TableRow>

                        <TableCell
                          colSpan={5}
                          className="py-10 text-center text-gray-500"
                        >
                          No se encontraron clientes.
                        </TableCell>

                      </TableRow>

                    ) : (

                      filteredProfiles.map(
                        (profile) => (
                          <TableRow
                            key={
                              profile.id
                            }
                          >

                            <TableCell>

                              <div className="font-medium">
                                {
                                  profile.nombre ||
                                  "Sin nombre"
                                }
                              </div>

                              <div className="text-xs text-gray-500">
                                {
                                  profile.email ||
                                  "Sin email"
                                }
                              </div>

                            </TableCell>

                            <TableCell>
                              {
                                profile.telefono ||
                                "Sin definir"
                              }
                            </TableCell>

                            <TableCell>

                              <div className="flex items-center gap-2">

                                <Building2 className="h-4 w-4 text-[#1E3A8A]" />

                                {
                                  getCompanyName(
                                    profile.company_id
                                  )
                                }

                              </div>

                            </TableCell>

                            <TableCell className="text-sm text-gray-500">
                              {profile.fecha_registro
                                ? format(
                                  new Date(
                                    profile.fecha_registro
                                  ),
                                  "dd/MM/yyyy"
                                )
                                : "-"}
                            </TableCell>

                            <TableCell className="text-center">

                              <button
                                type="button"
                                onClick={() =>
                                  handleOpenProfile(
                                    profile
                                  )
                                }
                                className="inline-flex items-center gap-2 rounded-lg border border-[#1E3A8A] px-3 py-2 text-xs font-semibold text-[#1E3A8A] hover:bg-[#1E3A8A] hover:text-white"
                              >
                                <UserCog className="h-4 w-4" />
                                Gestionar
                              </button>

                            </TableCell>

                          </TableRow>
                        )
                      )

                    )}

                  </TableBody>

                </Table>

              </div>

            </Card>

          </section>
        </div>

        {/* ======================================================
            PRESUPUESTOS
            ====================================================== */}

        <div
          hidden={
            activeTab !==
            "quotations"
          }
        >
          <section className="space-y-6">
            <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
              <div>
                <h2 className="text-2xl font-bold text-[#1E3A8A]">
                  Presupuestos
                </h2>
                <p className="mt-1 text-sm text-gray-500">
                  Consulta el estado, importes, fechas y documentos de los presupuestos comerciales.
                </p>
              </div>

              <div className="flex flex-wrap items-center gap-3">
                <Badge variant="outline" className="w-fit bg-white">
                  {filteredQuotations.length} presupuestos
                </Badge>
                <button
                  type="button"
                  onClick={handleNewQuotation}
                  className="inline-flex items-center gap-2 rounded-lg bg-[#1E3A8A] px-4 py-2 text-sm font-semibold text-white hover:bg-[#162D6B]"
                >
                  <Plus className="h-4 w-4" />
                  Nuevo presupuesto
                </button>
              </div>
            </div>

            <Card className="border-none p-4 shadow-md">
              <div className="grid gap-3 lg:grid-cols-[minmax(0,1fr)_220px_220px_180px]">
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
                  <Input
                    value={quotationSearch}
                    onChange={(event) => setQuotationSearch(event.target.value)}
                    placeholder="Buscar por nº, título, empresa, proyecto o cliente..."
                    className="h-11 pl-10"
                  />
                </div>

                <select
                  value={quotationCompanyFilter}
                  onChange={(event) => setQuotationCompanyFilter(event.target.value)}
                  className="h-11 rounded-md border border-input bg-background px-3 text-sm outline-none focus:ring-2 focus:ring-[#1E3A8A]/20"
                >
                  <option value="all">Todas las empresas</option>
                  {companies.map((company) => (
                    <option key={company.id} value={company.id}>
                      {company.company_name}
                    </option>
                  ))}
                </select>

                <select
                  value={quotationProjectFilter}
                  onChange={(event) => setQuotationProjectFilter(event.target.value)}
                  className="h-11 rounded-md border border-input bg-background px-3 text-sm outline-none focus:ring-2 focus:ring-[#1E3A8A]/20"
                >
                  <option value="all">Todos los proyectos</option>
                  {projects.map((project) => (
                    <option key={project.id} value={project.id}>
                      {project.nombre}
                    </option>
                  ))}
                </select>

                <select
                  value={quotationStatusFilter}
                  onChange={(event) => setQuotationStatusFilter(event.target.value)}
                  className="h-11 rounded-md border border-input bg-background px-3 text-sm outline-none focus:ring-2 focus:ring-[#1E3A8A]/20"
                >
                  <option value="all">Todos los estados</option>
                  <option value="pendiente">Pendiente</option>
                  <option value="aceptado">Aceptado</option>
                  <option value="rechazado">Rechazado</option>
                </select>
              </div>
            </Card>

            <Card className="overflow-hidden border-none shadow-md">
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader className="bg-gray-50">
                    <TableRow>
                      <TableHead className="font-bold">Nº presupuesto</TableHead>
                      <TableHead className="font-bold">Empresa</TableHead>
                      <TableHead className="font-bold">Proyecto</TableHead>
                      <TableHead className="font-bold">Cliente</TableHead>
                      <TableHead className="font-bold">Título</TableHead>
                      <TableHead className="font-bold text-right">Base</TableHead>
                      <TableHead className="font-bold text-center">IVA</TableHead>
                      <TableHead className="font-bold text-right">Total</TableHead>
                      <TableHead className="font-bold text-center">Estado</TableHead>
                      <TableHead className="font-bold">Emisión</TableHead>
                      <TableHead className="font-bold">Validez</TableHead>
                      <TableHead className="font-bold text-center">PDF</TableHead>
                      <TableHead className="font-bold text-center">Acciones</TableHead>
                    </TableRow>
                  </TableHeader>

                  <TableBody className="bg-white">
                    {filteredQuotations.length === 0 ? (
                      <TableRow>
                        <TableCell
                          colSpan={13}
                          className="py-14 text-center text-gray-500"
                        >
                          <FileText className="mx-auto mb-3 h-10 w-10 text-gray-300" />
                          <p className="font-semibold">No hay presupuestos que coincidan.</p>
                          <p className="mt-1 text-sm">
                            Prueba a cambiar la búsqueda o los filtros.
                          </p>
                        </TableCell>
                      </TableRow>
                    ) : (
                      filteredQuotations.map((quotation) => (
                        <TableRow key={quotation.id}>
                          <TableCell className="font-mono text-sm font-semibold text-[#1E3A8A]">
                            {quotation.numero_presupuesto}
                          </TableCell>

                          <TableCell>
                            {getCompanyName(quotation.company_id)}
                          </TableCell>

                          <TableCell>
                            {projects.find(
                              (project) => project.id === quotation.project_id
                            )?.nombre || "Sin proyecto"}
                          </TableCell>

                          <TableCell className="max-w-[180px]">
                            <span
                              className="block truncate text-xs text-gray-600"
                              title={quotation.client_id || ""}
                            >
                              {quotationClients.find((client) => client.id === quotation.client_id)?.nombre || "Sin cliente"}
                            </span>
                          </TableCell>

                          <TableCell className="min-w-[220px]">
                            <div className="font-medium text-gray-900">
                              {quotation.titulo}
                            </div>
                            {quotation.descripcion_detallada && (
                              <div
                                className="mt-1 max-w-[280px] truncate text-xs text-gray-500"
                                title={quotation.descripcion_detallada}
                              >
                                {quotation.descripcion_detallada}
                              </div>
                            )}
                          </TableCell>

                          <TableCell className="text-right">
                            {new Intl.NumberFormat("es-ES", {
                              style: "currency",
                              currency: "EUR",
                            }).format(Number(quotation.precio_base || 0))}
                          </TableCell>

                          <TableCell className="text-center">
                            {Number(quotation.iva_porcentaje || 0)}%
                          </TableCell>

                          <TableCell className="text-right font-semibold">
                            {new Intl.NumberFormat("es-ES", {
                              style: "currency",
                              currency: "EUR",
                            }).format(Number(quotation.precio_total || 0))}
                          </TableCell>

                          <TableCell className="text-center">
                            {getQuotationStatusBadge(quotation.estado)}
                          </TableCell>

                          <TableCell className="whitespace-nowrap text-sm text-gray-600">
                            {quotation.fecha_emision
                              ? format(new Date(quotation.fecha_emision), "dd/MM/yyyy")
                              : "—"}
                          </TableCell>

                          <TableCell className="whitespace-nowrap text-sm text-gray-600">
                            {quotation.fecha_validez
                              ? format(new Date(quotation.fecha_validez), "dd/MM/yyyy")
                              : "—"}
                          </TableCell>

                          <TableCell>
                            <div className="flex items-center justify-center gap-2">
                              {quotation.document_path && (
                                <button
                                  type="button"
                                  title="Ver PDF"
                                  disabled={openingQuotationPdf === quotation.id}
                                  onClick={() => handleOpenQuotationPdf(quotation)}
                                  className="rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50 disabled:opacity-50"
                                >
                                  {openingQuotationPdf === quotation.id ? (
                                    <Loader2 className="h-4 w-4 animate-spin" />
                                  ) : (
                                    <Eye className="h-4 w-4" />
                                  )}
                                </button>
                              )}

                              {quotation.document_path && (
                                <button
                                  type="button"
                                  title="Descargar PDF"
                                  disabled={openingQuotationPdf === quotation.id}
                                  onClick={() => handleDownloadQuotationPdf(quotation)}
                                  className="rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50 disabled:opacity-50"
                                >
                                  {openingQuotationPdf === quotation.id ? (
                                    <Loader2 className="h-4 w-4 animate-spin" />
                                  ) : (
                                    <Download className="h-4 w-4" />
                                  )}
                                </button>
                              )}

                              <label
                                title={
                                  quotation.document_path
                                    ? "Sustituir PDF"
                                    : "Adjuntar PDF"
                                }
                                className="cursor-pointer rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50"
                              >
                                {uploadingQuotationPdf === quotation.id ? (
                                  <Loader2 className="h-4 w-4 animate-spin" />
                                ) : (
                                  <Upload className="h-4 w-4" />
                                )}

                                <input
                                  type="file"
                                  accept="application/pdf,.pdf"
                                  className="hidden"
                                  disabled={uploadingQuotationPdf === quotation.id}
                                  onChange={(event) => {
                                    const file = event.target.files?.[0];
                                    event.currentTarget.value = "";
                                    if (file) {
                                      handleUploadQuotationPdf(quotation, file);
                                    }
                                  }}
                                />
                              </label>
                            </div>
                          </TableCell>

                          <TableCell>
                            <div className="flex items-center justify-center gap-2">
                              <button
                                type="button"
                                title="Editar presupuesto"
                                onClick={() => handleEditQuotation(quotation)}
                                className="rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50"
                              >
                                <Pencil className="h-4 w-4" />
                              </button>
                              <button
                                type="button"
                                title="Eliminar presupuesto"
                                onClick={() => handleDeleteQuotation(quotation)}
                                className="rounded-md border border-red-200 p-2 text-red-600 hover:bg-red-50"
                              >
                                <Trash2 className="h-4 w-4" />
                              </button>
                            </div>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </div>
            </Card>
          </section>
        </div>

        {/* ======================================================
            FACTURACIÓN
            ====================================================== */}

        <div
          hidden={
            activeTab !==
            "billing"
          }
        >
          <section className="space-y-6">

            <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">

              <h2 className="text-2xl font-bold text-[#1E3A8A]">
                Facturas
              </h2>

              <div className="flex flex-wrap items-center gap-3">

                <Badge
                  variant="outline"
                  className="bg-white"
                >
                  {
                    filteredInvoices.length
                  }{" "}
                  facturas
                </Badge>

                <button
                  type="button"
                  onClick={() => {
                    setEditingInvoice(null);
                    setSelectedInvoice(null);
                    setInvoiceError("");
                    setGeneratedInvoiceNumber("");

                    setInvoiceForm({
                      company_id: "",
                      project_id: "",
                      user_id: "",
                      numero_factura: "",
                      titulo: "",
                      descripcion_detallada: "",
                      servicios_incluidos: [
                        { descripcion: "", cantidad: 1, precio: 0 },
                      ],
                      precio_base: "",
                      iva_porcentaje: "21",
                      irpf_aplicado: false,
                      irpf_porcentaje: "0",
                      estado: "pendiente",
                      fecha_emision: getTodayForInput(),
                      fecha_vencimiento: "",
                      notas: "",
                    });

                    setInvoicePdfFile(null);
                    setShowCreateInvoice(true);
                  }}
                  className="rounded-lg bg-[#1E3A8A] px-4 py-2 text-sm font-semibold text-white hover:bg-[#162D6B]"
                >
                  + Crear factura
                </button>

              </div>

            </div>

            {/* FILTROS */}

            <div className="flex flex-wrap gap-4">

              <select
                value={
                  invoiceCompanyFilter
                }
                onChange={(event) =>
                  setInvoiceCompanyFilter(
                    event.target.value
                  )
                }
                className="rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm"
              >
                <option value="all">
                  Todas las empresas
                </option>

                {companies.map(
                  (company) => (
                    <option
                      key={
                        company.id
                      }
                      value={
                        company.id
                      }
                    >
                      {
                        company.company_name
                      }
                    </option>
                  )
                )}

              </select>

              <select
                value={
                  invoiceProjectFilter
                }
                onChange={(event) =>
                  setInvoiceProjectFilter(
                    event.target.value
                  )
                }
                className="rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm"
              >
                <option value="all">
                  Todos los proyectos
                </option>

                {invoiceProjects.map(
                  (project) => (
                    <option
                      key={
                        project.id
                      }
                      value={
                        project.id
                      }
                    >
                      {
                        project.nombre
                      }
                    </option>
                  )
                )}

              </select>

            </div>

            <Card className="overflow-hidden border-none shadow-md">
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader className="bg-gray-50">
                    <TableRow>
                      <TableHead className="font-bold">Nº factura</TableHead>
                      <TableHead className="font-bold">Empresa</TableHead>
                      <TableHead className="font-bold">Proyecto</TableHead>
                      <TableHead className="font-bold">Cliente</TableHead>
                      <TableHead className="font-bold">Título</TableHead>
                      <TableHead className="font-bold text-right">Base</TableHead>
                      <TableHead className="font-bold text-center">IVA</TableHead>
                      <TableHead className="font-bold text-right">Total</TableHead>
                      <TableHead className="font-bold text-center">Estado</TableHead>
                      <TableHead className="font-bold">Emisión</TableHead>
                      <TableHead className="font-bold">Vencimiento</TableHead>
                      <TableHead className="font-bold text-center">PDF</TableHead>
                      <TableHead className="font-bold text-center">Acciones</TableHead>
                    </TableRow>
                  </TableHeader>

                  <TableBody className="bg-white">
                    {filteredInvoices.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={13} className="py-14 text-center text-gray-500">
                          <FileText className="mx-auto mb-3 h-10 w-10 text-gray-300" />
                          <p className="font-semibold">No hay facturas que coincidan.</p>
                          <p className="mt-1 text-sm">
                            Prueba a cambiar la empresa o el proyecto seleccionado.
                          </p>
                        </TableCell>
                      </TableRow>
                    ) : (
                      filteredInvoices.map((invoice) => {
                        const invoiceTitle = getInvoiceTitle(invoice);
                        const invoiceDescription = getInvoiceDescriptionPreview(invoice);
                        const invoiceSubtotalValue = Number(
                          invoice.subtotal ??
                          Math.max(
                            Number(invoice.monto || 0) - Number(invoice.iva_importe || 0),
                            0
                          )
                        );
                        const invoiceIvaValue = Number(invoice.iva_porcentaje || 0);
                        const invoiceTotalValue = Number(invoice.monto || 0);

                        return (
                          <TableRow key={invoice.id}>
                            <TableCell className="font-mono text-sm font-semibold text-[#1E3A8A]">
                              {invoice.numero_factura}
                            </TableCell>

                            <TableCell>
                              {getCompanyName(invoice.company_id)}
                            </TableCell>

                            <TableCell>
                              {projects.find(
                                (project) => project.id === invoice.project_id
                              )?.nombre || "Sin proyecto"}
                            </TableCell>

                            <TableCell className="max-w-[180px]">
                              <span
                                className="block truncate text-xs text-gray-600"
                                title={invoice.user_id || ""}
                              >
                                {getInvoiceClientName(invoice)}
                              </span>
                            </TableCell>

                            <TableCell className="min-w-[220px]">
                              <div className="font-medium text-gray-900">
                                {invoiceTitle}
                              </div>
                              {invoiceDescription && (
                                <div
                                  className="mt-1 max-w-[280px] truncate text-xs text-gray-500"
                                  title={invoiceDescription}
                                >
                                  {invoiceDescription}
                                </div>
                              )}
                            </TableCell>

                            <TableCell className="text-right">
                              {new Intl.NumberFormat("es-ES", {
                                style: "currency",
                                currency: "EUR",
                              }).format(invoiceSubtotalValue)}
                            </TableCell>

                            <TableCell className="text-center">
                              {invoiceIvaValue}%
                            </TableCell>

                            <TableCell className="text-right font-semibold">
                              {new Intl.NumberFormat("es-ES", {
                                style: "currency",
                                currency: "EUR",
                              }).format(invoiceTotalValue)}
                            </TableCell>

                            <TableCell className="text-center">
                              {getInvoiceStatusBadge(invoice.estado)}
                            </TableCell>

                            <TableCell className="whitespace-nowrap text-sm text-gray-600">
                              {invoice.fecha_emision
                                ? format(new Date(invoice.fecha_emision), "dd/MM/yyyy")
                                : "—"}
                            </TableCell>

                            <TableCell className="whitespace-nowrap text-sm text-gray-600">
                              {invoice.fecha_vencimiento
                                ? format(new Date(invoice.fecha_vencimiento), "dd/MM/yyyy")
                                : "—"}
                            </TableCell>

                            <TableCell>
                              <div className="flex items-center justify-center gap-2">
                                {invoice.document_path ? (
                                  <>
                                    <button type="button" title="Ver PDF" disabled={openingInvoicePdf === invoice.id} onClick={() => handleOpenInvoicePdf(invoice)} className="rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50 disabled:opacity-50">
                                      {openingInvoicePdf === invoice.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Eye className="h-4 w-4" />}
                                    </button>
                                    <button type="button" title="Descargar PDF" disabled={openingInvoicePdf === invoice.id} onClick={() => handleDownloadInvoicePdf(invoice)} className="rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50 disabled:opacity-50">
                                      {openingInvoicePdf === invoice.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
                                    </button>
                                  </>
                                ) : <span className="text-sm text-gray-400">—</span>}
                              </div>
                            </TableCell>

                            <TableCell>
                              <div className="flex items-center justify-center gap-2">
                                <button type="button" title="Ver factura" onClick={() => handleViewInvoice(invoice)} className="rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50"><Eye className="h-4 w-4" /></button>
                                <button type="button" title="Editar factura" onClick={() => handleEditInvoice(invoice)} className="rounded-md border border-gray-200 p-2 text-[#1E3A8A] hover:bg-gray-50"><Pencil className="h-4 w-4" /></button>
                                <button type="button" title="Eliminar factura" disabled={deletingInvoice === invoice.id} onClick={() => handleDeleteInvoice(invoice)} className="rounded-md border border-red-200 p-2 text-red-600 hover:bg-red-50 disabled:opacity-50">
                                  {deletingInvoice === invoice.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
                                </button>
                              </div>
                            </TableCell>
                          </TableRow>
                        );
                      })
                    )}
                  </TableBody>
                </Table>
              </div>
            </Card>

          </section>
        </div>

        {/* ======================================================
            AUDITORÍAS
            ====================================================== */}

        <div
          hidden={
            activeTab !==
            "audits"
          }
        >
          <section className="space-y-6">

            <div className="flex items-center justify-between">

              <h2 className="text-2xl font-bold text-[#1E3A8A]">
                Solicitudes de auditoría
              </h2>

              <Badge
                variant="outline"
                className="bg-white"
              >
                {
                  auditRequests.length
                }{" "}
                solicitudes
              </Badge>

            </div>

            <Card className="overflow-hidden border-none shadow-md">

              <div className="overflow-x-auto">

                <Table>

                  <TableHeader className="bg-gray-50">

                    <TableRow>

                      <TableHead className="font-bold">
                        Nombre
                      </TableHead>

                      <TableHead className="font-bold">
                        Email
                      </TableHead>

                      <TableHead className="font-bold">
                        Empresa
                      </TableHead>

                      <TableHead className="text-center font-bold">
                        Empleados
                      </TableHead>

                      <TableHead className="font-bold">
                        Proceso
                      </TableHead>

                      <TableHead className="font-bold">
                        Estado
                      </TableHead>

                      <TableHead className="font-bold">
                        Fecha
                      </TableHead>

                    </TableRow>

                  </TableHeader>

                  <TableBody>

                    {auditRequests.length ===
                      0 ? (

                      <TableRow>

                        <TableCell
                          colSpan={7}
                          className="py-8 text-center text-gray-500"
                        >
                          No hay solicitudes de auditoría.
                        </TableCell>

                      </TableRow>

                    ) : (

                      auditRequests.map(
                        (request) => (
                          <TableRow
                            key={
                              request.id
                            }
                          >

                            <TableCell className="font-medium">
                              {
                                request.nombre
                              }
                            </TableCell>

                            <TableCell>
                              {
                                request.email
                              }
                            </TableCell>

                            <TableCell>
                              {
                                request.empresa
                              }
                            </TableCell>

                            <TableCell className="text-center">
                              {
                                request.empleados
                              }
                            </TableCell>

                            <TableCell
                              className="max-w-[200px] truncate"
                              title={
                                request.proceso ||
                                request.proceso_manual ||
                                ""
                              }
                            >
                              {
                                request.proceso ||
                                request.proceso_manual ||
                                "-"
                              }
                            </TableCell>

                            <TableCell>

                              <Badge
                                className="capitalize"
                              >
                                {
                                  request.status ||
                                  request.estado ||
                                  "pendiente"
                                }
                              </Badge>

                            </TableCell>

                            <TableCell className="text-sm text-gray-500">
                              {formatDate(
                                request.created_at
                              )}
                            </TableCell>

                          </TableRow>
                        )
                      )

                    )}

                  </TableBody>

                </Table>

              </div>

            </Card>

          </section>
        </div>

        {/* ======================================================
            TICKETS
            ====================================================== */}

        <div
          hidden={
            activeTab !==
            "tickets"
          }
        >
          <section className="space-y-6">

            <h2 className="text-2xl font-bold text-[#1E3A8A]">
              Tickets de soporte
            </h2>

            <Card className="overflow-hidden border-none shadow-md">

              <div className="overflow-x-auto">

                <Table>

                  <TableHeader className="bg-gray-50">

                    <TableRow>

                      <TableHead className="font-bold">
                        Cliente
                      </TableHead>

                      <TableHead className="font-bold">
                        Asunto
                      </TableHead>

                      <TableHead className="text-center font-bold">
                        Estado
                      </TableHead>

                      <TableHead className="text-center font-bold">
                        Prioridad
                      </TableHead>

                      <TableHead className="font-bold">
                        Fecha
                      </TableHead>

                    </TableRow>

                  </TableHeader>

                  <TableBody>

                    {tickets.length ===
                      0 ? (

                      <TableRow>

                        <TableCell
                          colSpan={5}
                          className="py-8 text-center text-gray-500"
                        >
                          No hay tickets.
                        </TableCell>

                      </TableRow>

                    ) : (

                      tickets.map(
                        (ticket) => (
                          <TableRow
                            key={
                              ticket.id
                            }
                          >

                            <TableCell>

                              <div className="font-medium">
                                {
                                  ticket
                                    .profiles
                                    ?.nombre ||
                                  "N/A"
                                }
                              </div>

                              <div className="text-xs text-gray-500">
                                {
                                  ticket
                                    .profiles
                                    ?.email ||
                                  ""
                                }
                              </div>

                            </TableCell>

                            <TableCell className="font-medium">
                              {
                                ticket.title
                              }
                            </TableCell>

                            <TableCell className="text-center">

                              <Badge
                                variant={
                                  ticket.status ===
                                    "open"
                                    ? "destructive"
                                    : "secondary"
                                }
                              >
                                {ticket.status ===
                                  "open"
                                  ? "Abierto"
                                  : ticket.status ===
                                    "closed"
                                    ? "Cerrado"
                                    : ticket.status}
                              </Badge>

                            </TableCell>

                            <TableCell className="text-center">

                              <span
                                className={`text-xs font-bold uppercase ${ticket.priority ===
                                    "high"
                                    ? "text-red-600"
                                    : ticket.priority ===
                                      "medium"
                                      ? "text-orange-600"
                                      : "text-blue-600"
                                  }`}
                              >
                                {
                                  ticket.priority
                                }
                              </span>

                            </TableCell>

                            <TableCell className="text-sm text-gray-500">
                              {formatDate(
                                ticket.created_at
                              )}
                            </TableCell>

                          </TableRow>
                        )
                      )

                    )}

                  </TableBody>

                </Table>

              </div>

            </Card>

          </section>
        </div>

        {/* ======================================================
            CONVERSACIONES IA
            ====================================================== */}

        <div
          hidden={
            activeTab !==
            "ai"
          }
        >
          <section className="space-y-6">

            <div className="flex items-center justify-between">

              <h2 className="text-2xl font-bold text-[#1E3A8A]">
                Conversaciones IA
              </h2>

              <Badge
                variant="outline"
                className="bg-white"
              >
                {
                  aiConversations.length
                }{" "}
                conversaciones
              </Badge>

            </div>

            <Card className="overflow-hidden border-none shadow-md">

              <div className="overflow-x-auto">

                <Table>

                  <TableHeader className="bg-gray-50">

                    <TableRow>

                      <TableHead className="font-bold">
                        Empresa
                      </TableHead>

                      <TableHead className="font-bold">
                        Tipo de negocio
                      </TableHead>

                      <TableHead className="font-bold">
                        Inicio
                      </TableHead>

                      <TableHead className="font-bold">
                        Última actividad
                      </TableHead>

                      <TableHead className="text-center font-bold">
                        Acción
                      </TableHead>

                    </TableRow>

                  </TableHeader>

                  <TableBody>

                    {aiConversations.length ===
                      0 ? (

                      <TableRow>

                        <TableCell
                          colSpan={5}
                          className="py-10 text-center text-gray-500"
                        >
                          No hay conversaciones IA.
                        </TableCell>

                      </TableRow>

                    ) : (

                      aiConversations.map(
                        (conversation) => (
                          <TableRow
                            key={
                              conversation.id
                            }
                          >

                            <TableCell className="font-medium">
                              {
                                conversation.company_name ||
                                "Sin empresa"
                              }
                            </TableCell>

                            <TableCell>
                              {
                                conversation.business_type ||
                                "-"
                              }
                            </TableCell>

                            <TableCell className="text-sm text-gray-500">
                              {formatDate(
                                conversation.created_at
                              )}
                            </TableCell>

                            <TableCell className="text-sm text-gray-500">
                              {formatDate(
                                conversation.updated_at
                              )}
                            </TableCell>

                            <TableCell className="text-center">

                              <button
                                type="button"
                                onClick={() =>
                                  handleOpenAIConversation(
                                    conversation
                                  )
                                }
                                className="rounded-lg border border-[#1E3A8A] px-3 py-2 text-xs font-semibold text-[#1E3A8A] hover:bg-[#1E3A8A] hover:text-white"
                              >
                                Ver conversación
                              </button>

                            </TableCell>

                          </TableRow>
                        )
                      )

                    )}

                  </TableBody>

                </Table>

              </div>

            </Card>

          </section>
        </div>

      </main>

      {/* ========================================================
          MODAL CREAR / EDITAR PRESUPUESTO
          ======================================================== */}

      {showQuotationForm && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4 py-6">
          <div className="max-h-[92vh] w-full max-w-5xl overflow-y-auto rounded-2xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-6 py-5">
              <div>
                <h3 className="text-xl font-bold text-[#1E3A8A]">
                  {editingQuotation ? "Editar presupuesto" : "Nuevo presupuesto"}
                </h3>
                <p className="mt-1 text-sm text-gray-500">
                  Completa los datos comerciales y, si quieres, adjunta el PDF definitivo.
                </p>
              </div>
              <button
                type="button"
                onClick={() => {
                  if (savingQuotation) return;
                  setShowQuotationForm(false);
                  setEditingQuotation(null);
                  setQuotationPdfFile(null);
                  setQuotationError("");
                }}
                className="rounded-lg p-2 text-gray-500 hover:bg-gray-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="space-y-6 p-6">
              {quotationError && (
                <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                  {quotationError}
                </div>
              )}

              <div className="grid gap-5 md:grid-cols-2">
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Empresa *</label>
                  <select
                    value={quotationForm.company_id}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        company_id: event.target.value,
                        project_id: "",
                        client_id: "",
                      }))
                    }
                    className="w-full rounded-lg border border-gray-200 bg-white px-3 py-2.5 text-sm outline-none focus:ring-2 focus:ring-[#1E3A8A]/20"
                  >
                    <option value="">Selecciona una empresa</option>
                    {companies.map((company) => (
                      <option key={company.id} value={company.id}>
                        {company.company_name}
                      </option>
                    ))}
                  </select>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Número de presupuesto{editingQuotation ? " *" : ""}</label>
                  <Input
                    value={quotationForm.numero_presupuesto}
                    placeholder="Se genera automáticamente al crear el presupuesto"
                    disabled
                  />

                  <p className="mt-1 text-xs text-gray-500">
                    El número de presupuesto lo genera automáticamente la base de datos y no puede modificarse.
                  </p>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Proyecto</label>
                  <select
                    value={quotationForm.project_id}
                    disabled={!quotationForm.company_id}
                    onChange={(event) => {
                      const projectId = event.target.value;
                      const selectedProject = projects.find(
                        (project) =>
                          String(project.id) === String(projectId)
                      );

                      setQuotationForm((current) => ({
                        ...current,
                        project_id: projectId,
                        client_id: selectedProject?.client_id || "",
                      }));
                    }}
                    className="w-full rounded-lg border border-gray-200 bg-white px-3 py-2.5 text-sm outline-none disabled:bg-gray-50"
                  >
                    <option value="">
                      {quotationForm.company_id ? "Sin proyecto" : "Selecciona primero una empresa"}
                    </option>
                    {quotationProjects.map((project) => (
                      <option key={project.id} value={project.id}>
                        {project.nombre}
                      </option>
                    ))}
                  </select>

                  {quotationForm.company_id &&
                    quotationProjects.length === 0 && (
                      <p className="mt-1 text-xs text-gray-400">
                        No hay proyectos asociados a esta empresa.
                      </p>
                    )}
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Usuario del proyecto</label>
                  <div className="w-full rounded-lg border border-gray-200 bg-gray-50 px-3 py-2.5 text-sm text-gray-600">
                    {selectedQuotationUser?.nombre ||
                      (quotationForm.project_id
                        ? "Usuario no identificado"
                        : "Selecciona primero un proyecto")}
                    {selectedQuotationUser?.email && (
                      <div className="mt-1 text-xs text-gray-400">
                        {selectedQuotationUser.email}
                      </div>
                    )}
                  </div>
                  <p className="mt-1 text-xs text-gray-400">
                    El usuario se obtiene automáticamente del proyecto y no puede editarse.
                  </p>
                </div>

                <div className="md:col-span-2">
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Título *</label>
                  <Input
                    value={quotationForm.titulo}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        titulo: event.target.value,
                      }))
                    }
                    placeholder="Título del presupuesto"
                  />
                </div>

                <div className="md:col-span-2">
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Descripción detallada</label>
                  <Textarea
                    value={quotationForm.descripcion_detallada}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        descripcion_detallada: event.target.value,
                      }))
                    }
                    rows={4}
                    placeholder="Describe el alcance del trabajo..."
                  />
                </div>
              </div>

              <div className="rounded-xl border border-gray-200 bg-gray-50 p-4">
                <div className="mb-4 flex items-center justify-between">
                  <div>
                    <h4 className="font-bold text-gray-900">Servicios incluidos</h4>
                    <p className="text-xs text-gray-500">La base imponible se calcula automáticamente.</p>
                  </div>
                  <button
                    type="button"
                    onClick={addQuotationService}
                    className="inline-flex items-center gap-2 rounded-lg border border-[#1E3A8A] px-3 py-2 text-xs font-semibold text-[#1E3A8A] hover:bg-white"
                  >
                    <Plus className="h-4 w-4" /> Añadir servicio
                  </button>
                </div>

                <div className="space-y-3">
                  {quotationForm.servicios_incluidos.map((service, index) => (
                    <div key={index} className="grid gap-3 rounded-lg border border-gray-200 bg-white p-3 md:grid-cols-[minmax(0,1fr)_120px_140px_44px]">
                      <Input
                        value={service.descripcion}
                        onChange={(event) => updateQuotationService(index, "descripcion", event.target.value)}
                        placeholder="Descripción del servicio"
                      />
                      <Input
                        type="number"
                        min="0"
                        step="0.01"
                        value={service.cantidad}
                        onChange={(event) => updateQuotationService(index, "cantidad", event.target.value)}
                        placeholder="Cantidad"
                      />
                      <Input
                        type="number"
                        min="0"
                        step="0.01"
                        value={service.precio}
                        onChange={(event) => updateQuotationService(index, "precio", event.target.value)}
                        placeholder="Precio"
                      />
                      <button
                        type="button"
                        title="Eliminar servicio"
                        disabled={quotationForm.servicios_incluidos.length <= 1}
                        onClick={() => removeQuotationService(index)}
                        className="flex items-center justify-center rounded-lg border border-red-200 text-red-600 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-30"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  ))}
                </div>
              </div>

              <div className="grid gap-5 md:grid-cols-4">
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Base imponible</label>
                  <Input
                    type="number"
                    min="0"
                    step="0.01"
                    value={quotationForm.precio_base}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        precio_base: event.target.value,
                      }))
                    }
                  />
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">IVA (%)</label>
                  <Input
                    type="number"
                    min="0"
                    step="0.01"
                    value={quotationForm.iva_porcentaje}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        iva_porcentaje: event.target.value,
                      }))
                    }
                  />
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Total</label>
                  <div className="flex h-10 items-center rounded-lg border border-gray-200 bg-gray-50 px-3 text-sm font-bold text-[#1E3A8A]">
                    {new Intl.NumberFormat("es-ES", { style: "currency", currency: "EUR" }).format(quotationTotal)}
                  </div>
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Estado</label>
                  <select
                    value={quotationForm.estado}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        estado: event.target.value,
                      }))
                    }
                    className="w-full rounded-lg border border-gray-200 bg-white px-3 py-2.5 text-sm"
                  >
                    <option value="Pendiente">Pendiente</option>
                    <option value="Aceptado">Aceptado</option>
                    <option value="Rechazado">Rechazado</option>
                  </select>
                </div>
              </div>

              <div className="grid gap-5 md:grid-cols-2">
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Fecha de emisión</label>
                  <Input
                    type="date"
                    value={quotationForm.fecha_emision}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        fecha_emision: event.target.value,
                      }))
                    }
                  />
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Fecha de validez</label>
                  <Input
                    type="date"
                    value={quotationForm.fecha_validez}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        fecha_validez: event.target.value,
                      }))
                    }
                  />
                </div>
                <div className="md:col-span-2">
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Notas</label>
                  <Textarea
                    value={quotationForm.notas}
                    onChange={(event) =>
                      setQuotationForm((current) => ({
                        ...current,
                        notas: event.target.value,
                      }))
                    }
                    rows={3}
                    placeholder="Notas internas o condiciones del presupuesto..."
                  />
                </div>
              </div>

              <div className="rounded-xl border border-dashed border-gray-300 bg-gray-50 p-5">
                <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
                  <div>
                    <h4 className="font-bold text-gray-900">Documento PDF</h4>
                    <p className="mt-1 text-xs text-gray-500">
                      PDF opcional. Máximo 10 MB. Se almacenará de forma privada.
                    </p>
                    {quotationPdfFile && (
                      <p className="mt-2 text-sm font-medium text-[#1E3A8A]">
                        {quotationPdfFile.name}
                      </p>
                    )}
                    {!quotationPdfFile && editingQuotation?.document_path && (
                      <p className="mt-2 text-xs text-green-600">Este presupuesto ya tiene un PDF adjunto.</p>
                    )}
                  </div>
                  <label className="inline-flex cursor-pointer items-center justify-center gap-2 rounded-lg border border-[#1E3A8A] px-4 py-2 text-sm font-semibold text-[#1E3A8A] hover:bg-white">
                    <Upload className="h-4 w-4" />
                    {editingQuotation?.document_path ? "Sustituir PDF" : "Adjuntar PDF"}
                    <input
                      type="file"
                      accept="application/pdf,.pdf"
                      className="hidden"
                      onChange={(event) => {
                        const file = event.target.files?.[0] || null;
                        event.currentTarget.value = "";
                        if (!file) return;
                        if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) {
                          alert("Solo se permiten archivos PDF.");
                          return;
                        }
                        if (file.size > 10 * 1024 * 1024) {
                          alert("El PDF no puede superar los 10 MB.");
                          return;
                        }
                        setQuotationPdfFile(file);
                      }}
                    />
                  </label>
                </div>
              </div>

              <div className="flex flex-col-reverse gap-3 border-t pt-5 sm:flex-row sm:justify-end">
                <button
                  type="button"
                  disabled={savingQuotation}
                  onClick={() => {
                    setShowQuotationForm(false);
                    setEditingQuotation(null);
                    setQuotationPdfFile(null);
                    setQuotationError("");
                  }}
                  className="rounded-lg border border-gray-200 px-5 py-2.5 text-sm font-semibold text-gray-700 hover:bg-gray-50 disabled:opacity-50"
                >
                  Cancelar
                </button>
                <button
                  type="button"
                  disabled={savingQuotation}
                  onClick={handleSaveQuotation}
                  className="inline-flex items-center justify-center gap-2 rounded-lg bg-[#1E3A8A] px-5 py-2.5 text-sm font-semibold text-white hover:bg-[#162D6B] disabled:opacity-50"
                >
                  {savingQuotation ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
                  {savingQuotation ? "Guardando..." : editingQuotation ? "Guardar cambios" : "Crear presupuesto"}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ========================================================
          MODAL GESTIÓN PERFIL
          ======================================================== */}

      {selectedProfile && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4">

          <div className="w-full max-w-xl rounded-2xl bg-white shadow-2xl">

            <div className="flex items-center justify-between border-b px-6 py-5">

              <div>
                <h3 className="text-xl font-bold text-[#1E3A8A]">
                  Gestionar perfil
                </h3>

                <p className="mt-1 text-sm text-gray-500">
                  {selectedProfile.nombre}
                </p>
              </div>

              <button
                type="button"
                onClick={() =>
                  setSelectedProfile(
                    null
                  )
                }
                className="text-2xl text-gray-400 hover:text-gray-700"
              >
                ×
              </button>

            </div>

            <div className="space-y-6 px-6 py-6">

              <div className="rounded-xl border bg-gray-50 p-4">

                <div className="flex items-center gap-3">

                  <div className="flex h-10 w-10 items-center justify-center rounded-full bg-[#1E3A8A]/10 text-[#1E3A8A]">
                    <User className="h-5 w-5" />
                  </div>

                  <div>

                    <p className="font-semibold text-gray-800">
                      {
                        selectedProfile.nombre
                      }
                    </p>

                    <p className="text-sm text-gray-500">
                      {
                        selectedProfile.email ||
                        "Sin email"
                      }
                    </p>

                  </div>

                </div>

              </div>

              <div>

                <label className="mb-2 block text-sm font-semibold text-gray-700">
                  Empresa asociada
                </label>

                <select
                  value={
                    selectedProfileCompanyId
                  }
                  onChange={(event) =>
                    setSelectedProfileCompanyId(
                      event.target.value
                    )
                  }
                  className="w-full rounded-lg border border-gray-200 bg-white px-3 py-3 text-sm outline-none focus:border-[#1E3A8A]"
                >

                  <option value="">
                    Sin empresa
                  </option>

                  {companies.map(
                    (company) => (
                      <option
                        key={
                          company.id
                        }
                        value={
                          company.id
                        }
                      >
                        {
                          company.company_name
                        }
                      </option>
                    )
                  )}

                </select>

              </div>

              <div className="rounded-lg border border-blue-100 bg-blue-50 p-4">

                <div className="flex gap-3">

                  <AlertCircle className="mt-0.5 h-5 w-5 flex-shrink-0 text-blue-700" />

                  <p className="text-sm text-blue-800">
                    Cambiar la empresa modificará la empresa asociada al perfil del cliente. El cambio se realizará mediante una operación protegida en Supabase.
                  </p>

                </div>

              </div>

            </div>

            <div className="flex justify-end gap-3 border-t bg-gray-50 px-6 py-4">

              <button
                type="button"
                onClick={() =>
                  setSelectedProfile(
                    null
                  )
                }
                className="rounded-lg border border-gray-200 bg-white px-5 py-2.5 text-sm font-semibold text-gray-700 hover:bg-gray-100"
              >
                Cancelar
              </button>

              <button
                type="button"
                disabled={
                  savingProfileCompany
                }
                onClick={
                  handleChangeProfileCompany
                }
                className="rounded-lg bg-[#1E3A8A] px-5 py-2.5 text-sm font-semibold text-white hover:bg-[#162D6B] disabled:cursor-not-allowed disabled:opacity-50"
              >
                {savingProfileCompany
                  ? "Guardando..."
                  : "Guardar empresa"}
              </button>

            </div>

          </div>

        </div>
      )}

      {/* ========================================================
          MODAL CREAR FACTURA
          ======================================================== */}

      {showCreateInvoice && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4 py-6">
          <div className="max-h-[92vh] w-full max-w-5xl overflow-y-auto rounded-2xl bg-white shadow-2xl">

            <div className="flex items-center justify-between border-b px-6 py-5">
              <div>
                <h3 className="text-xl font-bold text-[#1E3A8A]">
                  {editingInvoice ? "Editar factura" : "Nueva factura"}
                </h3>
                <p className="mt-1 text-sm text-gray-500">
                  Completa los datos de la factura. El usuario se obtiene automáticamente del proyecto.
                </p>
              </div>

              <button
                type="button"
                onClick={() => {
                  if (creatingInvoice) return;
                  setShowCreateInvoice(false);
                  setEditingInvoice(null);
                  setInvoicePdfFile(null);
                  setInvoiceError("");
                }}
                disabled={creatingInvoice}
                className="rounded-lg p-2 text-gray-500 hover:bg-gray-100 disabled:opacity-50"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="space-y-6 p-6">

              {invoiceError && (
                <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                  {invoiceError}
                </div>
              )}

              <div className="grid gap-5 md:grid-cols-2">

                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Empresa *</label>
                  <select
                    value={invoiceForm.company_id}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        company_id: event.target.value,
                        project_id: "",
                        user_id: "",
                      }))
                    }
                    className="w-full rounded-lg border border-gray-200 bg-white px-3 py-2.5 text-sm outline-none focus:ring-2 focus:ring-[#1E3A8A]/20 disabled:bg-gray-50"
                  >
                    <option value="">Selecciona una empresa</option>
                    {companies.map((company) => (
                      <option key={company.id} value={company.id}>
                        {company.company_name}
                      </option>
                    ))}
                  </select>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Número de factura</label>
                  <Input
                    value={generatedInvoiceNumber || invoiceForm.numero_factura}
                    placeholder="Se genera automáticamente al crear la factura"
                    disabled
                  />
                  <p className="mt-1 text-xs text-gray-500">
                    El número lo genera automáticamente la base de datos y no puede modificarse.
                  </p>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Proyecto *</label>
                  <select
                    value={invoiceForm.project_id}
                    disabled={!invoiceForm.company_id || creatingInvoice}
                    onChange={(event) => {
                      const projectId = event.target.value;
                      const selectedProject = projects.find(
                        (project) =>
                          String(project.id) === String(projectId)
                      );

                      setInvoiceForm((current) => ({
                        ...current,
                        project_id: projectId,
                        user_id: selectedProject?.user_id || "",
                      }));
                    }}
                    className="w-full rounded-lg border border-gray-200 bg-white px-3 py-2.5 text-sm outline-none disabled:bg-gray-50"
                  >
                    <option value="">
                      {invoiceForm.company_id
                        ? "Selecciona un proyecto"
                        : "Selecciona primero una empresa"}
                    </option>
                    {createInvoiceProjects.map((project) => (
                      <option key={project.id} value={project.id}>
                        {project.nombre}
                      </option>
                    ))}
                  </select>
                </div>

                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Usuario del proyecto</label>
                  <div className="w-full rounded-lg border border-gray-200 bg-gray-50 px-3 py-2.5 text-sm text-gray-600">
                    {selectedInvoiceUser?.nombre ||
                      (invoiceForm.project_id
                        ? "Usuario no identificado"
                        : "Selecciona primero un proyecto")}
                    {selectedInvoiceUser?.email && (
                      <div className="mt-1 text-xs text-gray-400">
                        {selectedInvoiceUser.email}
                      </div>
                    )}
                  </div>
                  <p className="mt-1 text-xs text-gray-400">
                    El usuario se obtiene automáticamente del proyecto y no puede editarse.
                  </p>
                </div>

                <div className="md:col-span-2">
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Título *</label>
                  <Input
                    value={invoiceForm.titulo}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        titulo: event.target.value,
                      }))
                    }
                    placeholder="Título de la factura"
                  />
                </div>

                <div className="md:col-span-2">
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Descripción detallada</label>
                  <Textarea
                    value={invoiceForm.descripcion_detallada}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        descripcion_detallada: event.target.value,
                      }))
                    }
                    rows={4}
                    placeholder="Describe el trabajo o alcance de la factura..."
                  />
                </div>
              </div>

              <div className="rounded-xl border border-gray-200 bg-gray-50 p-4">
                <div className="mb-4 flex items-center justify-between">
                  <div>
                    <h4 className="font-bold text-gray-900">Servicios incluidos</h4>
                    <p className="text-xs text-gray-500">La base imponible se calcula automáticamente.</p>
                  </div>
                  <button
                    type="button"
                    disabled={creatingInvoice}
                    onClick={() =>
                      setInvoiceForm((current) => ({
                        ...current,
                        servicios_incluidos: [
                          ...current.servicios_incluidos,
                          { descripcion: "", cantidad: 1, precio: 0 },
                        ],
                      }))
                    }
                    className="inline-flex items-center gap-2 rounded-lg border border-[#1E3A8A] px-3 py-2 text-xs font-semibold text-[#1E3A8A] hover:bg-white disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    <Plus className="h-4 w-4" /> Añadir servicio
                  </button>
                </div>

                <div className="space-y-3">
                  {invoiceForm.servicios_incluidos.map((service, index) => (
                    <div
                      key={index}
                      className="grid gap-3 rounded-lg border border-gray-200 bg-white p-3 md:grid-cols-[minmax(0,1fr)_120px_140px_44px]"
                    >
                      <Input
                        value={service.descripcion}
                        disabled={creatingInvoice}
                        onChange={(event) =>
                          setInvoiceForm((current) => {
                            const services = [...current.servicios_incluidos];
                            services[index] = {
                              ...services[index],
                              descripcion: event.target.value,
                            };
                            return {
                              ...current,
                              servicios_incluidos: services,
                            };
                          })
                        }
                        placeholder="Descripción del servicio"
                      />
                      <Input
                        type="number"
                        min="0"
                        step="0.01"
                        value={service.cantidad}
                        disabled={creatingInvoice}
                        onChange={(event) =>
                          setInvoiceForm((current) => {
                            const services = [...current.servicios_incluidos];
                            services[index] = {
                              ...services[index],
                              cantidad: Number(event.target.value || 0),
                            };
                            return {
                              ...current,
                              servicios_incluidos: services,
                              precio_base: calculateQuotationSubtotal(services).toFixed(2),
                            };
                          })
                        }
                        placeholder="Cantidad"
                      />
                      <Input
                        type="number"
                        min="0"
                        step="0.01"
                        value={service.precio}
                        disabled={creatingInvoice}
                        onChange={(event) =>
                          setInvoiceForm((current) => {
                            const services = [...current.servicios_incluidos];
                            services[index] = {
                              ...services[index],
                              precio: Number(event.target.value || 0),
                            };
                            return {
                              ...current,
                              servicios_incluidos: services,
                              precio_base: calculateQuotationSubtotal(services).toFixed(2),
                            };
                          })
                        }
                        placeholder="Precio"
                      />
                      <button
                        type="button"
                        title="Eliminar servicio"
                        disabled={creatingInvoice || invoiceForm.servicios_incluidos.length <= 1}
                        onClick={() =>
                          setInvoiceForm((current) => {
                            const services = current.servicios_incluidos.filter(
                              (_, serviceIndex) => serviceIndex !== index
                            );
                            return {
                              ...current,
                              servicios_incluidos: services,
                              precio_base: calculateQuotationSubtotal(services).toFixed(2),
                            };
                          })
                        }
                        className="flex items-center justify-center rounded-lg border border-red-200 text-red-600 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-30"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  ))}
                </div>
              </div>

              <div className="grid gap-5 md:grid-cols-4">
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Base imponible</label>
                  <Input
                    type="number"
                    min="0"
                    step="0.01"
                    value={invoiceForm.precio_base}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        precio_base: event.target.value,
                      }))
                    }
                  />
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">IVA (%)</label>
                  <Input
                    type="number"
                    min="0"
                    max="100"
                    step="0.01"
                    value={invoiceForm.iva_porcentaje}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        iva_porcentaje: event.target.value,
                      }))
                    }
                  />
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Total</label>
                  <div className="flex h-10 items-center rounded-lg border border-gray-200 bg-gray-50 px-3 text-sm font-bold text-[#1E3A8A]">
                    {new Intl.NumberFormat("es-ES", { style: "currency", currency: "EUR" }).format(invoiceTotal)}
                  </div>
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Estado</label>
                  {editingInvoice ? (
                    <select value={invoiceForm.estado} disabled={creatingInvoice} onChange={(event) => setInvoiceForm((current) => ({ ...current, estado: event.target.value }))} className="h-10 w-full rounded-lg border border-gray-200 bg-white px-3 text-sm font-semibold text-gray-700">
                      <option value="pendiente">Pendiente</option>
                      <option value="pagada">Pagada</option>
                      <option value="vencida">Vencida</option>
                      <option value="cancelada">Cancelada</option>
                    </select>
                  ) : (
                    <div className="flex h-10 items-center rounded-lg border border-gray-200 bg-yellow-50 px-3 text-sm font-bold text-yellow-700">Pendiente</div>
                  )}
                </div>
              </div>

              <div className="grid gap-5 md:grid-cols-2">
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Fecha de emisión</label>
                  <Input
                    type="date"
                    value={invoiceForm.fecha_emision}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        fecha_emision: event.target.value,
                      }))
                    }
                  />
                </div>
                <div>
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Fecha de vencimiento</label>
                  <Input
                    type="date"
                    value={invoiceForm.fecha_vencimiento}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        fecha_vencimiento: event.target.value,
                      }))
                    }
                  />
                </div>
                <div className="md:col-span-2">
                  <label className="mb-2 block text-sm font-semibold text-gray-700">Notas</label>
                  <Textarea
                    value={invoiceForm.notas}
                    disabled={creatingInvoice}
                    onChange={(event) =>
                      setInvoiceForm((current) => ({
                        ...current,
                        notas: event.target.value,
                      }))
                    }
                    rows={3}
                    placeholder="Notas internas o condiciones de la factura..."
                  />
                </div>
              </div>

              <div className="rounded-xl border border-dashed border-gray-300 bg-gray-50 p-5">
                <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
                  <div>
                    <h4 className="font-bold text-gray-900">Documento PDF</h4>
                    <p className="mt-1 text-xs text-gray-500">
                      PDF opcional. Máximo 10 MB. Se almacenará de forma privada.
                    </p>
                    {invoicePdfFile && (
                      <p className="mt-2 text-sm font-medium text-[#1E3A8A]">
                        {invoicePdfFile.name}
                      </p>
                    )}
                  </div>

                  <label
                    className={`inline-flex cursor-pointer items-center justify-center gap-2 rounded-lg border border-[#1E3A8A] px-4 py-2 text-sm font-semibold text-[#1E3A8A] hover:bg-white ${creatingInvoice ? "cursor-not-allowed opacity-50" : ""
                      }`}
                  >
                    <Upload className="h-4 w-4" />
                    {invoicePdfFile ? "Sustituir PDF" : "Adjuntar PDF"}
                    <input
                      type="file"
                      accept="application/pdf,.pdf"
                      className="hidden"
                      disabled={creatingInvoice}
                      onChange={(event) => {
                        const file = event.target.files?.[0] || null;
                        event.currentTarget.value = "";
                        if (!file) return;

                        if (
                          file.type !== "application/pdf" &&
                          !file.name.toLowerCase().endsWith(".pdf")
                        ) {
                          alert("Solo se permiten archivos PDF.");
                          return;
                        }

                        if (file.size > 10 * 1024 * 1024) {
                          alert("El PDF no puede superar los 10 MB.");
                          return;
                        }

                        setInvoicePdfFile(file);
                      }}
                    />
                  </label>
                </div>
              </div>

              <div className="flex flex-col-reverse gap-3 border-t pt-5 sm:flex-row sm:justify-end">
                <button
                  type="button"
                  disabled={creatingInvoice}
                  onClick={() => {
                    setShowCreateInvoice(false);
                    setInvoicePdfFile(null);
                    setInvoiceError("");
                  }}
                  className="rounded-lg border border-gray-200 px-5 py-2.5 text-sm font-semibold text-gray-700 hover:bg-gray-50 disabled:opacity-50"
                >
                  Cancelar
                </button>
                <button
                  type="button"
                  disabled={creatingInvoice}
                  onClick={handleCreateInvoice}
                  className="inline-flex items-center justify-center gap-2 rounded-lg bg-[#1E3A8A] px-5 py-2.5 text-sm font-semibold text-white hover:bg-[#162D6B] disabled:opacity-50"
                >
                  {creatingInvoice
                    ? editingInvoice ? "Guardando cambios..." : "Creando factura..."
                    : editingInvoice ? "Guardar cambios" : "Crear factura"}
                </button>
              </div>

            </div>
          </div>
        </div>
      )}

      {/* ========================================================
          MODAL VER FACTURA
          ======================================================== */}

      {selectedInvoice && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4 py-6">
          <div className="max-h-[90vh] w-full max-w-3xl overflow-y-auto rounded-2xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-6 py-5">
              <div>
                <h3 className="text-xl font-bold text-[#1E3A8A]">Factura {selectedInvoice.numero_factura}</h3>
                <p className="mt-1 text-sm text-gray-500">Consulta los datos de la factura.</p>
              </div>
              <button type="button" onClick={() => setSelectedInvoice(null)} className="rounded-lg p-2 text-gray-500 hover:bg-gray-100"><X className="h-5 w-5" /></button>
            </div>
            <div className="grid gap-5 p-6 md:grid-cols-2">
              <div><p className="text-xs font-semibold uppercase text-gray-400">Empresa</p><p className="mt-1 font-medium">{getCompanyName(selectedInvoice.company_id)}</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Proyecto</p><p className="mt-1 font-medium">{projects.find((p) => p.id === selectedInvoice.project_id)?.nombre || "Sin proyecto"}</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Usuario</p><p className="mt-1 font-medium">{getInvoiceClientName(selectedInvoice)}</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Estado</p><div className="mt-1">{getInvoiceStatusBadge(selectedInvoice.estado)}</div></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Título</p><p className="mt-1 font-medium">{getInvoiceTitle(selectedInvoice)}</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Base</p><p className="mt-1 font-medium">{new Intl.NumberFormat("es-ES", { style: "currency", currency: "EUR" }).format(Number(selectedInvoice.subtotal || 0))}</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">IVA</p><p className="mt-1 font-medium">{Number(selectedInvoice.iva_porcentaje || 0)}%</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Total</p><p className="mt-1 font-bold text-[#1E3A8A]">{new Intl.NumberFormat("es-ES", { style: "currency", currency: "EUR" }).format(Number(selectedInvoice.monto || 0))}</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Emisión</p><p className="mt-1">{selectedInvoice.fecha_emision ? format(new Date(selectedInvoice.fecha_emision), "dd/MM/yyyy") : "—"}</p></div>
              <div><p className="text-xs font-semibold uppercase text-gray-400">Vencimiento</p><p className="mt-1">{selectedInvoice.fecha_vencimiento ? format(new Date(selectedInvoice.fecha_vencimiento), "dd/MM/yyyy") : "—"}</p></div>
              <div className="md:col-span-2"><p className="text-xs font-semibold uppercase text-gray-400">Descripción</p><div className="mt-2 whitespace-pre-wrap rounded-lg border border-gray-200 bg-gray-50 p-4 text-sm text-gray-700">{selectedInvoice.descripcion || "Sin descripción."}</div></div>
            </div>
            <div className="flex flex-wrap justify-end gap-3 border-t bg-gray-50 px-6 py-4">
              {selectedInvoice.document_path && <><button type="button" onClick={() => handleOpenInvoicePdf(selectedInvoice)} className="inline-flex items-center gap-2 rounded-lg border border-[#1E3A8A] px-4 py-2.5 text-sm font-semibold text-[#1E3A8A] hover:bg-blue-50"><Eye className="h-4 w-4" />Ver PDF</button><button type="button" onClick={() => handleDownloadInvoicePdf(selectedInvoice)} className="inline-flex items-center gap-2 rounded-lg border border-[#1E3A8A] px-4 py-2.5 text-sm font-semibold text-[#1E3A8A] hover:bg-blue-50"><Download className="h-4 w-4" />Descargar PDF</button></>}
              <button type="button" onClick={() => handleEditInvoice(selectedInvoice)} className="inline-flex items-center gap-2 rounded-lg bg-[#1E3A8A] px-4 py-2.5 text-sm font-semibold text-white hover:bg-[#162D6B]"><Pencil className="h-4 w-4" />Editar</button>
              <button type="button" onClick={() => setSelectedInvoice(null)} className="rounded-lg border border-gray-200 bg-white px-4 py-2.5 text-sm font-semibold text-gray-700 hover:bg-gray-100">Cerrar</button>
            </div>
          </div>
        </div>
      )}

      {/* ========================================================
          MODAL CONVERSACIÓN IA
          ======================================================== */}

      {selectedAIConversation && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4">

          <div className="flex max-h-[85vh] w-full max-w-4xl flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">

            <div className="flex items-center justify-between border-b px-6 py-5">

              <div>
                <h3 className="text-xl font-bold text-[#1E3A8A]">
                  Conversación IA
                </h3>

                <p className="mt-1 text-sm text-gray-500">
                  {
                    selectedAIConversation.company_name ||
                    "Sin empresa"
                  }
                </p>
              </div>

              <button
                type="button"
                onClick={() =>
                  setSelectedAIConversation(
                    null
                  )
                }
                className="text-2xl text-gray-400 hover:text-gray-700"
              >
                ×
              </button>

            </div>

            <div className="flex-1 overflow-y-auto bg-[#F5F7FA] px-6 py-6">

              {loadingAIConversation ? (

                <div className="flex justify-center py-16">

                  <RefreshCw className="h-8 w-8 animate-spin text-[#1E3A8A]" />

                </div>

              ) : aiMessages.length ===
                0 ? (

                <div className="py-16 text-center text-gray-500">
                  No hay mensajes registrados.
                </div>

              ) : (

                <div className="space-y-5">

                  {aiMessages.map(
                    (message) => {

                      const isUser =
                        message.role ===
                        "user";

                      return (
                        <div
                          key={
                            message.id
                          }
                          className={`flex ${isUser
                              ? "justify-end"
                              : "justify-start"
                            }`}
                        >

                          <div className="max-w-[80%]">

                            <div
                              className={`mb-1 px-1 text-xs font-semibold ${isUser
                                  ? "text-right text-gray-500"
                                  : "text-left text-[#1E3A8A]"
                                }`}
                            >
                              {isUser
                                ? "Visitante"
                                : "Modira AI"}
                            </div>

                            <div
                              className={`rounded-2xl px-4 py-3 text-sm leading-relaxed shadow-sm ${isUser
                                  ? "rounded-br-md bg-[#1E3A8A] text-white"
                                  : "rounded-bl-md border border-gray-200 bg-white text-gray-800"
                                }`}
                            >
                              <div className="whitespace-pre-wrap">
                                {
                                  message.content
                                }
                              </div>
                            </div>

                            <div
                              className={`mt-1 px-1 text-[11px] text-gray-400 ${isUser
                                  ? "text-right"
                                  : "text-left"
                                }`}
                            >
                              {formatDate(
                                message.created_at
                              )}
                            </div>

                          </div>

                        </div>
                      );
                    }
                  )}

                </div>

              )}

            </div>

            <div className="flex justify-end border-t bg-white px-6 py-4">

              <button
                type="button"
                onClick={() =>
                  setSelectedAIConversation(
                    null
                  )
                }
                className="rounded-lg border border-gray-200 bg-white px-5 py-2.5 text-sm font-semibold text-gray-700 hover:bg-gray-100"
              >
                Cerrar
              </button>

            </div>

          </div>

        </div>
      )}

      {/* ========================================================
          FOOTER
          ======================================================== */}

      <footer className="mt-12 border-t bg-white py-8">

        <div className="container mx-auto px-4 text-center text-sm text-gray-500">

          <p>
            © {new Date().getFullYear()} Modira.
            Panel de Gestión Interna.
          </p>

        </div>

      </footer>

    </div>
  );
}