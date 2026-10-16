import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/contexts/AuthContext";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";

import {
  Zap,
  Plus,
  Search,
  ArrowLeft,
  Loader2,
  AlertCircle,
  Filter,
  X,
  Eye,
  Download,
  FileText,
  MessageSquare,
  CheckCircle2,
  Clock,
  XCircle,
} from "lucide-react";

import { useLocation } from "wouter";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";

import { toast } from "sonner";

import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

/* ============================================================
   TIPOS
============================================================ */

type ProjectStatus =
  | "Pendiente"
  | "Activo"
  | "Pausado"
  | "Entregado"
  | "Completado"
  | string;

type ChangeRequestStatus =
  | "pending"
  | "in_review"
  | "accepted"
  | "rejected"
  | "completed"
  | string;

interface Project {
  id: string;
  user_id: string;
  company_id: string | null;
  client_id?: string | null;

  nombre: string;
  descripcion: string | null;

  estado: ProjectStatus;

  fecha_inicio: string;
  fecha_fin: string | null;

  created_at: string;

  /*
   * MIGRACIÓN 014
   */
  change_requests_enabled?: boolean;
  change_requests_deadline?: string | null;
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

  reviewed_by: string | null;
  reviewed_at: string | null;

  review_notes: string | null;

  accepted_at: string | null;

  completed_by: string | null;
  completed_at: string | null;

  created_at: string;
  updated_at: string;
}

/* ============================================================
   HELPERS
============================================================ */

const formatDate = (
  value: string | null | undefined
) => {
  if (!value) {
    return "-";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "-";
  }

  return date.toLocaleDateString("es-ES");
};

const formatDateTime = (
  value: string | null | undefined
) => {
  if (!value) {
    return "-";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "-";
  }

  return date.toLocaleString("es-ES", {
    dateStyle: "short",
    timeStyle: "short",
  });
};

const formatFileSize = (
  bytes: number
) => {
  if (
    !Number.isFinite(bytes) ||
    bytes <= 0
  ) {
    return "-";
  }

  if (bytes < 1024) {
    return `${bytes} B`;
  }

  if (bytes < 1024 * 1024) {
    return `${(
      bytes / 1024
    ).toFixed(1)} KB`;
  }

  return `${(
    bytes /
    (1024 * 1024)
  ).toFixed(1)} MB`;
};

const normalizeChangeRequestStatus = (
  status: string | null | undefined
): ChangeRequestStatus => {
  return String(status || "")
    .trim()
    .toLowerCase();
};

const getChangeRequestStatusLabel = (
  status: string | null | undefined
) => {
  switch (
    normalizeChangeRequestStatus(status)
  ) {
    case "pending":
      return "Pendiente";

    case "in_review":
      return "En revisión";

    case "accepted":
      return "Aceptada";

    case "rejected":
      return "Rechazada";

    case "completed":
      return "Completada";

    default:
      return status || "Pendiente";
  }
};

/* ============================================================
   COMPONENTE
============================================================ */

export default function ProjectsList() {
  const { user } = useAuth();
  const [, setLocation] = useLocation();

  /* ==========================================================
     PROYECTOS
  ========================================================== */

  const [projects, setProjects] =
    useState<Project[]>([]);

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState<string | null>(null);

  /* ==========================================================
     FILTROS
  ========================================================== */

  const [searchTerm, setSearchTerm] =
    useState("");

  const [statusFilter, setStatusFilter] =
    useState<string>("all");

  /* ==========================================================
     CREAR PROYECTO
  ========================================================== */

  const [
    isCreateDialogOpen,
    setIsCreateDialogOpen,
  ] = useState(false);

  const [isCreating, setIsCreating] =
    useState(false);

  const [createForm, setCreateForm] =
    useState({
      descripcion: "",
      fecha_inicio:
        new Date()
          .toISOString()
          .split("T")[0],
      fecha_fin: "",
    });

  /* ==========================================================
     HEADER
  ========================================================== */

  const [isScrolled, setIsScrolled] =
    useState(false);

  /* ==========================================================
     DOCUMENTOS
  ========================================================== */

  const [documents, setDocuments] =
    useState<ProjectDocument[]>([]);

  const [openingDocument, setOpeningDocument] =
    useState<string | null>(null);

  /* ==========================================================
     SOLICITUDES DE CAMBIO
  ========================================================== */

  const [
    changeRequests,
    setChangeRequests,
  ] = useState<ProjectChangeRequest[]>([]);

  const [
    isChangeRequestDialogOpen,
    setIsChangeRequestDialogOpen,
  ] = useState(false);

  const [
    changeRequestProject,
    setChangeRequestProject,
  ] = useState<Project | null>(null);

  const [
    changeRequestDescription,
    setChangeRequestDescription,
  ] = useState("");

  const [
    submittingChangeRequest,
    setSubmittingChangeRequest,
  ] = useState(false);

  /* ==========================================================
     PROYECTO SELECCIONADO
  ========================================================== */

  const [
    selectedProject,
    setSelectedProject,
  ] = useState<Project | null>(null);

  /* ============================================================
     SCROLL HEADER
  ============================================================ */

  useEffect(() => {
    const handleScroll = () => {
      setIsScrolled(
        window.scrollY > 10
      );
    };

    window.addEventListener(
      "scroll",
      handleScroll
    );

    return () =>
      window.removeEventListener(
        "scroll",
        handleScroll
      );
  }, []);

  /* ============================================================
     CARGAR DATOS
  ============================================================ */

  const fetchProjects = async () => {
    if (!user) {
      setLoading(false);
      return;
    }

    try {
      setLoading(true);
      setError(null);

      /* --------------------------------------------------------
         1. PROYECTOS DEL CLIENTE
      -------------------------------------------------------- */

      const {
        data: projectData,
        error: projectError,
      } = await supabase
        .from("projects")
        .select("*")
        .eq("user_id", user.id)
        .order("created_at", {
          ascending: false,
        });

      if (projectError) {
        throw projectError;
      }

      const loadedProjects =
        (projectData ||
          []) as Project[];

      setProjects(
        loadedProjects
      );

      /* --------------------------------------------------------
         IDS
      -------------------------------------------------------- */

      const projectIds =
        loadedProjects.map(
          (project) =>
            project.id
        );

      /* --------------------------------------------------------
         2. DOCUMENTOS
      -------------------------------------------------------- */

      if (
        projectIds.length > 0
      ) {
        const {
          data: documentData,
          error: documentError,
        } = await supabase
          .from(
            "project_documents"
          )
          .select(
            `
              id,
              project_id,
              file_name,
              storage_path,
              mime_type,
              file_size,
              uploaded_by,
              created_at,
              updated_at
            `
          )
          .in(
            "project_id",
            projectIds
          )
          .order(
            "created_at",
            {
              ascending: false,
            }
          );

        if (documentError) {
          console.warn(
            "[ProjectsList] No se pudieron cargar los documentos:",
            documentError
          );

          setDocuments([]);
        } else {
          setDocuments(
            (documentData ||
              []) as ProjectDocument[]
          );
        }

        /* ------------------------------------------------------
           3. SOLICITUDES DE CAMBIO
        ------------------------------------------------------ */

        const {
          data: requestData,
          error: requestError,
        } = await supabase
          .from(
            "project_change_requests"
          )
          .select("*")
          .in(
            "project_id",
            projectIds
          )
          .order(
            "created_at",
            {
              ascending: false,
            }
          );

        if (requestError) {
          console.warn(
            "[ProjectsList] No se pudieron cargar las solicitudes:",
            requestError
          );

          setChangeRequests([]);
        } else {
          setChangeRequests(
            (requestData ||
              []) as ProjectChangeRequest[]
          );
        }
      } else {
        setDocuments([]);
        setChangeRequests([]);
      }
    } catch (err: any) {
      console.error(
        "[ProjectsList] Error cargando proyectos:",
        err
      );

      setError(
        err?.message ||
          "No se pudieron cargar los proyectos."
      );

      setProjects([]);
      setDocuments([]);
      setChangeRequests([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchProjects();
  }, [user]);

  /* ============================================================
     CREAR PROYECTO
  ============================================================ */

  const handleCreateProject =
    async () => {
      if (
        !user ||
        !createForm.descripcion.trim()
      ) {
        toast.error(
          "La descripción del proyecto es obligatoria."
        );

        return;
      }

      try {
        setIsCreating(true);

        const {
          error: insertError,
        } = await supabase.rpc(
          "create_project",
          {
            p_descripcion:
              createForm.descripcion.trim(),

            p_fecha_inicio:
              new Date(
                createForm.fecha_inicio
              ).toISOString(),

            p_fecha_fin:
              createForm.fecha_fin
                ? new Date(
                    createForm.fecha_fin
                  ).toISOString()
                : null,
          }
        );

        if (insertError) {
          throw insertError;
        }

        toast.success(
          "Proyecto creado correctamente."
        );

        setIsCreateDialogOpen(
          false
        );

        setCreateForm({
          descripcion: "",
          fecha_inicio:
            new Date()
              .toISOString()
              .split("T")[0],
          fecha_fin: "",
        });

        await fetchProjects();
      } catch (err: any) {
        console.error(
          "[ProjectsList] Error creando proyecto:",
          err
        );

        toast.error(
          err?.message ||
            "No se pudo crear el proyecto."
        );
      } finally {
        setIsCreating(false);
      }
    };

  /* ============================================================
     ESTADOS
  ============================================================ */

  const getStatusBadge = (
    estado: ProjectStatus
  ) => {
    switch (estado) {
      case "Pendiente":
        return (
          <Badge className="border-none bg-gray-100 text-gray-700 hover:bg-gray-100">
            Pendiente
          </Badge>
        );

      case "Activo":
        return (
          <Badge className="border-none bg-green-100 text-green-700 hover:bg-green-100">
            Activo
          </Badge>
        );

      case "Pausado":
        return (
          <Badge className="border-none bg-yellow-100 text-yellow-700 hover:bg-yellow-100">
            Pausado
          </Badge>
        );

      case "Entregado":
        return (
          <Badge className="border-none bg-purple-100 text-purple-700 hover:bg-purple-100">
            Entregado
          </Badge>
        );

      case "Completado":
        return (
          <Badge className="border-none bg-blue-100 text-blue-700 hover:bg-blue-100">
            Completado
          </Badge>
        );

      default:
        return (
          <Badge variant="outline">
            {estado}
          </Badge>
        );
    }
  };

  /* ============================================================
     FILTROS
  ============================================================ */

  const filteredProjects =
    useMemo(() => {
      const query =
        searchTerm
          .trim()
          .toLowerCase();

      return projects.filter(
        (project) => {
          const matchesSearch =
            !query ||
            project.nombre
              .toLowerCase()
              .includes(query) ||
            (
              project.descripcion ||
              ""
            )
              .toLowerCase()
              .includes(query);

          const matchesStatus =
            statusFilter ===
              "all" ||
            project.estado ===
              statusFilter;

          return (
            matchesSearch &&
            matchesStatus
          );
        }
      );
    }, [
      projects,
      searchTerm,
      statusFilter,
    ]);

  /* ============================================================
     DOCUMENTOS
  ============================================================ */

  const getProjectDocuments = (
    projectId: string
  ) => {
    return documents.filter(
      (documentItem) =>
        documentItem.project_id ===
        projectId
    );
  };

  /* ============================================================
     SOLICITUD ACTIVA
  ============================================================ */

  const getActiveChangeRequest = (
    projectId: string
  ) => {
    return (
      changeRequests.find(
        (request) =>
          request.project_id ===
            projectId &&
          [
            "pending",
            "in_review",
            "accepted",
          ].includes(
            normalizeChangeRequestStatus(
              request.status
            )
          )
      ) || null
    );
  };

  /* ============================================================
     ÚLTIMA SOLICITUD
  ============================================================ */

  const getLatestChangeRequest = (
    projectId: string
  ) => {
    return (
      changeRequests.find(
        (request) =>
          request.project_id ===
          projectId
      ) || null
    );
  };

  /* ============================================================
     ¿PUEDE SOLICITAR CAMBIO?
  ============================================================ */

  const canRequestChanges = (
    project: Project
  ) => {
    if (
      project.change_requests_enabled !==
      true
    ) {
      return false;
    }

    if (
      !project.change_requests_deadline
    ) {
      return false;
    }

    const deadline =
      new Date(
        project.change_requests_deadline
      );

    if (
      Number.isNaN(
        deadline.getTime()
      )
    ) {
      return false;
    }

    if (
      new Date() >
      deadline
    ) {
      return false;
    }

    const activeRequest =
      getActiveChangeRequest(
        project.id
      );

    if (activeRequest) {
      return false;
    }

    return true;
  };

  /* ============================================================
     ABRIR PROYECTO
  ============================================================ */

  const handleOpenProject = (
    project: Project
  ) => {
    setSelectedProject(
      project
    );
  };

  /* ============================================================
     CERRAR PROYECTO
  ============================================================ */

  const handleCloseProject = () => {
    setSelectedProject(null);
  };

  /* ============================================================
     ABRIR SOLICITUD DE CAMBIO
     ------------------------------------------------------------
     IMPORTANTE:
     NO abrimos este diálogo dentro del diálogo de proyecto.
     Primero cerramos el proyecto y guardamos el proyecto en
     changeRequestProject.
  ============================================================ */

  const handleOpenChangeRequest =
    (project?: Project) => {
      const targetProject =
        project ||
        selectedProject;

      if (!targetProject) {
        toast.error(
          "No se ha seleccionado ningún proyecto."
        );

        return;
      }

      if (
        !canRequestChanges(
          targetProject
        )
      ) {
        toast.info(
          "Este proyecto no permite solicitar cambios en este momento."
        );

        return;
      }

      setChangeRequestProject(
        targetProject
      );

      setChangeRequestDescription(
        ""
      );

      /*
       * Cerramos el modal del proyecto
       * antes de abrir el modal de solicitud.
       */
      setSelectedProject(null);

      setIsChangeRequestDialogOpen(
        true
      );
    };

  /* ============================================================
     CERRAR SOLICITUD
  ============================================================ */

  const handleCloseChangeRequest =
    () => {
      if (
        submittingChangeRequest
      ) {
        return;
      }

      setIsChangeRequestDialogOpen(
        false
      );

      setChangeRequestDescription(
        ""
      );

      setChangeRequestProject(
        null
      );
    };

  /* ============================================================
     ENVIAR SOLICITUD
  ============================================================ */

  const handleSubmitChangeRequest =
    async () => {
      if (
        !changeRequestProject
      ) {
        toast.error(
          "No se ha seleccionado ningún proyecto."
        );

        return;
      }

      const description =
        changeRequestDescription.trim();

      if (!description) {
        toast.error(
          "Describe el cambio que necesitas solicitar."
        );

        return;
      }

      if (
        description.length >
        5000
      ) {
        toast.error(
          "La descripción no puede superar los 5000 caracteres."
        );

        return;
      }

      if (
        !canRequestChanges(
          changeRequestProject
        )
      ) {
        toast.error(
          "El periodo para solicitar cambios no está disponible."
        );

        return;
      }

      try {
        setSubmittingChangeRequest(
          true
        );

        const {
          data,
          error: requestError,
        } = await supabase.rpc(
          "request_project_change",
          {
            p_project_id:
              changeRequestProject.id,

            p_description:
              description,
          }
        );

        if (requestError) {
          throw requestError;
        }

        /*
         * La RPC 014 devuelve la solicitud creada.
         */

        const createdRequest =
          data as
            | ProjectChangeRequest
            | null;

        if (
          createdRequest
        ) {
          setChangeRequests(
            (current) => [
              createdRequest,
              ...current,
            ]
          );
        }

        /*
         * Cerramos el diálogo.
         */

        setIsChangeRequestDialogOpen(
          false
        );

        setChangeRequestDescription(
          ""
        );

        setChangeRequestProject(
          null
        );

        /*
         * Recargamos para que el estado
         * quede sincronizado con Supabase.
         */

        await fetchProjects();

        toast.success(
          "Solicitud de cambio enviada correctamente."
        );
      } catch (err: any) {
        console.error(
          "[ProjectsList] Error enviando solicitud:",
          err
        );

        toast.error(
          err?.message ||
            "No se pudo enviar la solicitud de cambio."
        );
      } finally {
        setSubmittingChangeRequest(
          false
        );
      }
    };

  /* ============================================================
     ABRIR PDF
  ============================================================ */

  const openProjectPdf =
    async (
      file: ProjectDocument
    ) => {
      if (!file.storage_path) {
        toast.info(
          "Este documento no tiene una ruta disponible."
        );

        return;
      }

      setOpeningDocument(
        file.id
      );

      try {
        const {
          data,
          error:
            signedUrlError,
        } =
          await supabase.storage
            .from(
              "project-documents"
            )
            .createSignedUrl(
              file.storage_path,
              300
            );

        if (signedUrlError) {
          throw signedUrlError;
        }

        if (
          !data?.signedUrl
        ) {
          throw new Error(
            "No se pudo generar el enlace seguro del PDF."
          );
        }

        window.open(
          data.signedUrl,
          "_blank",
          "noopener,noreferrer"
        );
      } catch (err: any) {
        console.error(
          "[ProjectsList] Error abriendo PDF:",
          err
        );

        toast.error(
          err?.message ||
            "No se ha podido abrir el PDF."
        );
      } finally {
        setOpeningDocument(
          null
        );
      }
    };

  /* ============================================================
     DESCARGAR PDF
  ============================================================ */

  const downloadProjectPdf =
    async (
      file: ProjectDocument
    ) => {
      if (!file.storage_path) {
        toast.info(
          "Este documento no tiene una ruta disponible."
        );

        return;
      }

      setOpeningDocument(
        file.id
      );

      try {
        const {
          data,
          error:
            signedUrlError,
        } =
          await supabase.storage
            .from(
              "project-documents"
            )
            .createSignedUrl(
              file.storage_path,
              300,
              {
                download:
                  file.file_name ||
                  "documento.pdf",
              }
            );

        if (signedUrlError) {
          throw signedUrlError;
        }

        if (
          !data?.signedUrl
        ) {
          throw new Error(
            "No se pudo generar el enlace seguro del PDF."
          );
        }

        const response =
          await fetch(
            data.signedUrl
          );

        if (!response.ok) {
          throw new Error(
            "No se pudo descargar el PDF."
          );
        }

        const blob =
          await response.blob();

        const url =
          URL.createObjectURL(
            blob
          );

        const anchor =
          window.document.createElement(
            "a"
          );

        anchor.href = url;

        anchor.download =
          file.file_name ||
          "documento.pdf";

        window.document.body.appendChild(
          anchor
        );

        anchor.click();

        anchor.remove();

        URL.revokeObjectURL(
          url
        );
      } catch (err: any) {
        console.error(
          "[ProjectsList] Error descargando PDF:",
          err
        );

        toast.error(
          err?.message ||
            "No se ha podido descargar el PDF."
        );
      } finally {
        setOpeningDocument(
          null
        );
      }
    };

  /* ============================================================
     LOADING
  ============================================================ */

  if (loading) {
    return (
      <div className="min-h-screen bg-white">

        <header className="fixed left-0 top-0 z-50 h-[80px] w-full bg-gradient-to-r from-[#102A66] to-[#173B8F] shadow-lg">

          <nav className="container mx-auto flex h-[80px] items-center justify-between px-4 md:pl-10">

            <div className="flex items-center gap-3">

              <img
                src="/Images/logo-modira-blanco.png"
                alt="Modira"
                className="h-8 w-auto object-contain"
              />

              <span className="modira-font text-xl text-white">
                Proyectos
              </span>

            </div>

          </nav>

        </header>

        <div className="flex min-h-screen items-center justify-center pt-[80px]">

          <div className="text-center">

            <Loader2
              className="mx-auto mb-4 h-12 w-12 animate-spin text-[#173B8F]"
            />

            <p className="text-[#52627A]">
              Cargando tus proyectos...
            </p>

          </div>

        </div>

      </div>
    );
  }

  /* ============================================================
     RENDER
  ============================================================ */

  return (
    <div className="min-h-screen bg-[#F5F7FA]">

      {/* ========================================================
          HEADER
      ======================================================== */}

      <header
        className={`fixed left-0 top-0 z-50 h-[80px] w-full transition-all duration-300 ${
          isScrolled
            ? "border-b border-[#102A66]/10 bg-white/95 shadow-lg backdrop-blur-md"
            : "bg-gradient-to-r from-[#102A66] to-[#173B8F] shadow-lg"
        }`}
      >

        <nav className="container mx-auto flex h-[80px] items-center justify-between px-4 md:pl-10">

          <div className="flex h-full shrink-0 items-center gap-3">

            <img
              src={
                isScrolled
                  ? "/Images/logo-modira-azul.png"
                  : "/Images/logo-modira-blanco.png"
              }
              alt="Modira"
              className="h-8 w-auto object-contain transition-all duration-300"
            />

            <span
              className={`modira-font flex translate-y-[2px] items-center text-xl leading-none transition-colors duration-300 ${
                isScrolled
                  ? "text-[#102A66]"
                  : "text-white"
              }`}
            >
              Proyectos
            </span>

          </div>

          <div className="hidden flex-1 items-center justify-center px-8 md:flex">

            <span
              className={`text-center text-[14px] font-bold italic transition-colors duration-300 ${
                isScrolled
                  ? "text-[#102A66]/80"
                  : "text-white/90"
              }`}
            >
              Consulta, revisa y gestiona la información de tus proyectos.
            </span>

          </div>

          <Button
            type="button"
            onClick={() =>
              setLocation(
                "/area-cliente"
              )
            }
            className={`shrink-0 font-medium transition-all ${
              isScrolled
                ? "bg-[#102A66] text-white hover:bg-[#173B8F]"
                : "bg-white text-[#102A66] hover:bg-white/90"
            }`}
          >
            <ArrowLeft className="mr-2 h-4 w-4" />
            Área de Clientes
          </Button>

        </nav>

      </header>

      {/* ========================================================
          CONTENIDO
      ======================================================== */}

      <main className="container mx-auto px-4 pb-16 pt-[112px]">

        {/* ERROR */}

        {error && (
          <Card className="mb-8 border-red-200 bg-red-50 p-5 text-red-700">

            <div className="flex items-start gap-3">

              <AlertCircle className="mt-0.5 h-5 w-5 shrink-0" />

              <div>

                <p className="font-semibold">
                  No se han podido cargar los proyectos
                </p>

                <p className="mt-1 text-sm">
                  {error}
                </p>

              </div>

            </div>

          </Card>
        )}

        {/* ======================================================
            CABECERA
        ====================================================== */}

        <section className="mb-8">

          <div className="flex flex-col gap-5 md:flex-row md:items-end md:justify-between">

            <div>

              <p className="text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Área de cliente
              </p>

              <h1 className="mt-2 text-3xl font-bold text-[#102A66] md:text-4xl">
                Mis proyectos
              </h1>

              <p className="mt-2 max-w-2xl text-[#52627A]">
                Consulta el estado de tus proyectos,
                revisa los documentos disponibles y
                solicita cambios cuando el periodo esté abierto.
              </p>

            </div>

            <Button
              type="button"
              onClick={() =>
                setIsCreateDialogOpen(
                  true
                )
              }
              className="bg-[#173B8F] text-white hover:bg-[#102A66]"
            >
              <Plus className="mr-2 h-4 w-4" />
              Crear proyecto
            </Button>

          </div>

        </section>

        {/* ======================================================
            FILTROS
        ====================================================== */}

        <Card className="mb-8 border border-[#E8ECF2] bg-white p-4">

          <div className="flex flex-col gap-3 md:flex-row">

            <div className="relative flex-1">

              <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[#7B8798]" />

              <Input
                value={searchTerm}
                onChange={(event) =>
                  setSearchTerm(
                    event.target.value
                  )
                }
                placeholder="Buscar por nombre o descripción..."
                className="border-[#E8ECF2] pl-10"
              />

            </div>

            <div className="flex gap-2">

              <div className="flex items-center gap-2">

                <Filter className="h-4 w-4 text-[#52627A]" />

                <Select
                  value={
                    statusFilter
                  }
                  onValueChange={
                    setStatusFilter
                  }
                >

                  <SelectTrigger className="w-[180px] border-[#E8ECF2]">
                    <SelectValue />
                  </SelectTrigger>

                  <SelectContent>

                    <SelectItem value="all">
                      Todos los estados
                    </SelectItem>

                    <SelectItem value="Pendiente">
                      Pendiente
                    </SelectItem>

                    <SelectItem value="Activo">
                      Activo
                    </SelectItem>

                    <SelectItem value="Pausado">
                      Pausado
                    </SelectItem>

                    <SelectItem value="Entregado">
                      Entregado
                    </SelectItem>

                    <SelectItem value="Completado">
                      Completado
                    </SelectItem>

                  </SelectContent>

                </Select>

              </div>

              {(searchTerm ||
                statusFilter !==
                  "all") && (
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => {
                    setSearchTerm("");
                    setStatusFilter(
                      "all"
                    );
                  }}
                >
                  <X className="mr-1 h-4 w-4" />
                  Limpiar
                </Button>
              )}

            </div>

          </div>

        </Card>

        {/* ======================================================
            CONTADOR
        ====================================================== */}

        <div className="mb-4 flex items-center justify-between">

          <p className="text-sm text-[#52627A]">

            {filteredProjects.length}{" "}
            {filteredProjects.length ===
            1
              ? "proyecto"
              : "proyectos"}

          </p>

        </div>

        {/* ======================================================
            LISTADO
        ====================================================== */}

        {filteredProjects.length ===
        0 ? (

          <Card className="border border-[#E8ECF2] bg-white p-12 text-center">

            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-[#173B8F]/10 text-[#173B8F]">

              <Zap className="h-7 w-7" />

            </div>

            <h2 className="mt-5 text-xl font-bold text-[#102A66]">
              No hay proyectos
            </h2>

            <p className="mx-auto mt-2 max-w-md text-[#52627A]">
              No se encontraron proyectos con
              los filtros seleccionados.
            </p>

            {(searchTerm ||
              statusFilter !==
                "all") && (
              <Button
                type="button"
                variant="outline"
                className="mt-5"
                onClick={() => {
                  setSearchTerm("");
                  setStatusFilter(
                    "all"
                  );
                }}
              >
                Limpiar filtros
              </Button>
            )}

          </Card>

        ) : (

          <div className="space-y-3">

            {filteredProjects.map(
              (project) => {

                const projectDocuments =
                  getProjectDocuments(
                    project.id
                  );

                const activeRequest =
                  getActiveChangeRequest(
                    project.id
                  );

                const latestRequest =
                  getLatestChangeRequest(
                    project.id
                  );

                return (
                  <Card
                    key={project.id}
                    className="border border-[#E8ECF2] bg-white transition-all duration-200 hover:border-[#173B8F]/30 hover:shadow-md"
                  >

                    <div className="flex flex-col gap-5 p-5 md:flex-row md:items-center md:justify-between">

                      {/* INFORMACIÓN */}

                      <div className="flex min-w-0 items-start gap-4">

                        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F]">

                          <Zap className="h-5 w-5" />

                        </div>

                        <div className="min-w-0">

                          <div className="mb-1 flex flex-wrap items-center gap-2">

                            <h3 className="truncate text-lg font-bold text-[#102A66]">
                              {project.nombre}
                            </h3>

                            {getStatusBadge(
                              project.estado
                            )}

                          </div>

                          <p className="line-clamp-2 max-w-3xl text-sm text-[#52627A]">

                            {project.descripcion ||
                              "Sin descripción disponible."}

                          </p>

                          <div className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-xs text-[#7B8798]">

                            <span>
                              Inicio:{" "}
                              <strong className="text-[#52627A]">
                                {formatDate(
                                  project.fecha_inicio
                                )}
                              </strong>
                            </span>

                            {project.fecha_fin && (
                              <span>
                                Finalización:{" "}
                                <strong className="text-[#52627A]">
                                  {formatDate(
                                    project.fecha_fin
                                  )}
                                </strong>
                              </span>
                            )}

                            <span>
                              {projectDocuments.length}{" "}
                              {projectDocuments.length ===
                              1
                                ? "documento"
                                : "documentos"}
                            </span>

                          </div>

                          {activeRequest && (
                            <div className="mt-2 flex items-center gap-2 text-xs font-medium text-amber-700">

                              <Clock className="h-3.5 w-3.5" />

                              Solicitud de cambio:{" "}
                              {
                                getChangeRequestStatusLabel(
                                  activeRequest.status
                                )
                              }

                            </div>
                          )}

                          {!activeRequest &&
                            latestRequest && (
                              <div
                                className={`mt-2 flex items-center gap-2 text-xs font-medium ${
                                  normalizeChangeRequestStatus(
                                    latestRequest.status
                                  ) ===
                                  "completed"
                                    ? "text-green-700"
                                    : normalizeChangeRequestStatus(
                                        latestRequest.status
                                      ) ===
                                      "rejected"
                                    ? "text-red-700"
                                    : "text-[#52627A]"
                                }`}
                              >

                                {normalizeChangeRequestStatus(
                                  latestRequest.status
                                ) ===
                                  "completed" ? (
                                  <CheckCircle2 className="h-3.5 w-3.5" />
                                ) : normalizeChangeRequestStatus(
                                    latestRequest.status
                                  ) ===
                                  "rejected" ? (
                                  <XCircle className="h-3.5 w-3.5" />
                                ) : (
                                  <Clock className="h-3.5 w-3.5" />
                                )}

                                Última solicitud:{" "}
                                {
                                  getChangeRequestStatusLabel(
                                    latestRequest.status
                                  )
                                }

                              </div>
                            )}

                        </div>

                      </div>

                      {/* ACCIONES */}

                      <div className="flex shrink-0 items-center gap-2">

                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          onClick={() =>
                            handleOpenProject(
                              project
                            )
                          }
                          className="gap-2 border-[#DCE2EA] text-[#173B8F] hover:bg-[#F4F7FB]"
                        >
                          <Eye className="h-4 w-4" />
                          Ver
                        </Button>

                      </div>

                    </div>

                  </Card>
                );
              }
            )}

          </div>

        )}

      </main>

      {/* ========================================================
          MODAL CREAR PROYECTO
      ======================================================== */}

      <Dialog
        open={
          isCreateDialogOpen
        }
        onOpenChange={
          setIsCreateDialogOpen
        }
      >

        <DialogContent className="sm:max-w-lg">

          <DialogHeader>

            <DialogTitle>
              Crear proyecto
            </DialogTitle>

            <DialogDescription>
              Introduce la información básica del proyecto.
            </DialogDescription>

          </DialogHeader>

          <div className="space-y-5">

            <div className="space-y-2">

              <Label>
                Descripción
              </Label>

              <Textarea
                value={
                  createForm.descripcion
                }
                onChange={(event) =>
                  setCreateForm(
                    (current) => ({
                      ...current,
                      descripcion:
                        event.target
                          .value,
                    })
                  )
                }
                placeholder="Describe el proyecto..."
                rows={5}
              />

            </div>

            <div className="grid gap-4 md:grid-cols-2">

              <div className="space-y-2">

                <Label>
                  Fecha de inicio
                </Label>

                <Input
                  type="date"
                  value={
                    createForm.fecha_inicio
                  }
                  onChange={(event) =>
                    setCreateForm(
                      (current) => ({
                        ...current,
                        fecha_inicio:
                          event.target
                            .value,
                      })
                    )
                  }
                />

              </div>

              <div className="space-y-2">

                <Label>
                  Fecha de finalización
                </Label>

                <Input
                  type="date"
                  value={
                    createForm.fecha_fin
                  }
                  onChange={(event) =>
                    setCreateForm(
                      (current) => ({
                        ...current,
                        fecha_fin:
                          event.target
                            .value,
                      })
                    )
                  }
                />

              </div>

            </div>

          </div>

          <DialogFooter>

            <Button
              type="button"
              variant="outline"
              onClick={() =>
                setIsCreateDialogOpen(
                  false
                )
              }
              disabled={isCreating}
            >
              Cancelar
            </Button>

            <Button
              type="button"
              onClick={
                handleCreateProject
              }
              disabled={isCreating}
              className="bg-[#173B8F] text-white hover:bg-[#102A66]"
            >

              {isCreating ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : (
                <Plus className="mr-2 h-4 w-4" />
              )}

              Crear proyecto

            </Button>

          </DialogFooter>

        </DialogContent>

      </Dialog>

      {/* ========================================================
          MODAL DETALLE DEL PROYECTO

          IMPORTANTE:
          Este modal NO contiene el modal de solicitud.
          Al pulsar "Solicitar cambio", el proyecto se guarda en
          changeRequestProject y este diálogo se cierra.
      ======================================================== */}

      <Dialog
        open={
          !!selectedProject
        }
        onOpenChange={(
          open
        ) => {
          if (!open) {
            handleCloseProject();
          }
        }}
      >

        <DialogContent className="max-h-[90vh] overflow-y-auto p-0 sm:max-w-3xl">

          {selectedProject && (
            <>

              <DialogHeader className="border-b border-[#E8ECF2] px-6 py-5">

                <div className="flex flex-wrap items-center gap-2">

                  <DialogTitle className="text-2xl text-[#102A66]">
                    {selectedProject.nombre}
                  </DialogTitle>

                  {getStatusBadge(
                    selectedProject.estado
                  )}

                </div>

                <DialogDescription>
                  Información, documentos y solicitudes relacionadas con este proyecto.
                </DialogDescription>

              </DialogHeader>

              <div className="space-y-7 px-6 py-6">

                {/* ==================================================
                    INFORMACIÓN
                ================================================== */}

                <section>

                  <p className="mb-3 text-sm font-semibold uppercase tracking-wide text-[#52627A]">
                    Información del proyecto
                  </p>

                  <div className="grid gap-4 rounded-xl border border-[#E8ECF2] bg-[#FAFBFD] p-5 md:grid-cols-2">

                    <div>

                      <p className="text-xs font-semibold uppercase tracking-wide text-[#7B8798]">
                        Descripción
                      </p>

                      <p className="mt-1 whitespace-pre-wrap text-sm text-[#182230]">
                        {selectedProject.descripcion ||
                          "Sin descripción disponible."}
                      </p>

                    </div>

                    <div>

                      <p className="text-xs font-semibold uppercase tracking-wide text-[#7B8798]">
                        Estado
                      </p>

                      <div className="mt-2">
                        {getStatusBadge(
                          selectedProject.estado
                        )}
                      </div>

                    </div>

                    <div>

                      <p className="text-xs font-semibold uppercase tracking-wide text-[#7B8798]">
                        Fecha de inicio
                      </p>

                      <p className="mt-1 text-sm font-medium text-[#182230]">
                        {formatDate(
                          selectedProject.fecha_inicio
                        )}
                      </p>

                    </div>

                    <div>

                      <p className="text-xs font-semibold uppercase tracking-wide text-[#7B8798]">
                        Fecha de finalización
                      </p>

                      <p className="mt-1 text-sm font-medium text-[#182230]">
                        {selectedProject.fecha_fin
                          ? formatDate(
                              selectedProject.fecha_fin
                            )
                          : "Sin fecha de finalización"}
                      </p>

                    </div>

                  </div>

                </section>

                {/* ==================================================
                    DOCUMENTOS
                ================================================== */}

                <section>

                  <div className="mb-3">

                    <p className="text-sm font-semibold uppercase tracking-wide text-[#52627A]">
                      Documentos del proyecto
                    </p>

                    <p className="mt-1 text-sm text-[#7B8798]">
                      Aquí aparecerán los documentos PDF que Modira haya adjuntado a este proyecto.
                    </p>

                  </div>

                  {getProjectDocuments(
                    selectedProject.id
                  ).length === 0 ? (

                    <div className="rounded-xl border border-dashed border-[#DCE2EA] bg-[#FAFBFD] p-6 text-center">

                      <FileText className="mx-auto h-8 w-8 text-[#94A3B8]" />

                      <p className="mt-3 text-sm font-medium text-[#52627A]">
                        Todavía no hay documentos.
                      </p>

                    </div>

                  ) : (

                    <div className="space-y-3">

                      {getProjectDocuments(
                        selectedProject.id
                      ).map(
                        (file) => (

                          <div
                            key={
                              file.id
                            }
                            className="flex flex-col gap-3 rounded-xl border border-[#E8ECF2] bg-white p-4 sm:flex-row sm:items-center sm:justify-between"
                          >

                            <div className="flex min-w-0 items-center gap-3">

                              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-red-50 text-red-600">

                                <FileText className="h-5 w-5" />

                              </div>

                              <div className="min-w-0">

                                <p className="truncate text-sm font-semibold text-[#182230]">
                                  {file.file_name}
                                </p>

                                <p className="mt-1 text-xs text-[#7B8798]">
                                  PDF ·{" "}
                                  {formatFileSize(
                                    Number(
                                      file.file_size
                                    )
                                  )}
                                </p>

                              </div>

                            </div>

                            <div className="flex shrink-0 gap-2">

                              <Button
                                type="button"
                                variant="outline"
                                size="sm"
                                disabled={
                                  openingDocument ===
                                  file.id
                                }
                                onClick={() =>
                                  openProjectPdf(
                                    file
                                  )
                                }
                                className="gap-2 border-[#DCE2EA] text-[#173B8F] hover:bg-[#F4F7FB]"
                              >

                                {openingDocument ===
                                file.id ? (
                                  <Loader2 className="h-4 w-4 animate-spin" />
                                ) : (
                                  <Eye className="h-4 w-4" />
                                )}

                                Ver PDF

                              </Button>

                              <Button
                                type="button"
                                variant="outline"
                                size="sm"
                                disabled={
                                  openingDocument ===
                                  file.id
                                }
                                onClick={() =>
                                  downloadProjectPdf(
                                    file
                                  )
                                }
                                className="gap-2 border-[#DCE2EA] text-[#173B8F] hover:bg-[#F4F7FB]"
                              >

                                {openingDocument ===
                                file.id ? (
                                  <Loader2 className="h-4 w-4 animate-spin" />
                                ) : (
                                  <Download className="h-4 w-4" />
                                )}

                                Descargar PDF

                              </Button>

                            </div>

                          </div>

                        )
                      )}

                    </div>

                  )}

                </section>

                {/* ==================================================
                    SOLICITUDES DE CAMBIO
                ================================================== */}

                <section>

                  <div className="mb-3">

                    <p className="text-sm font-semibold uppercase tracking-wide text-[#52627A]">
                      Solicitudes de cambio
                    </p>

                    <p className="mt-1 text-sm text-[#7B8798]">
                      Solicita modificaciones sobre el proyecto cuando el periodo esté habilitado.
                    </p>

                  </div>

                  {(() => {

                    const activeRequest =
                      getActiveChangeRequest(
                        selectedProject.id
                      );

                    const latestRequest =
                      getLatestChangeRequest(
                        selectedProject.id
                      );

                    /* ==========================================
                       SOLICITUD ACTIVA
                    ========================================== */

                    if (
                      activeRequest
                    ) {

                      return (
                        <div className="rounded-xl border border-amber-200 bg-amber-50 p-5">

                          <div className="flex items-start gap-3">

                            <Clock className="mt-0.5 h-5 w-5 shrink-0 text-amber-600" />

                            <div className="min-w-0">

                              <p className="font-semibold text-amber-900">
                                Tienes una solicitud de cambio en curso
                              </p>

                              <p className="mt-1 text-sm text-amber-800">

                                Estado:{" "}

                                <strong>
                                  {
                                    getChangeRequestStatusLabel(
                                      activeRequest.status
                                    )
                                  }
                                </strong>

                              </p>

                              <p className="mt-3 whitespace-pre-wrap text-sm text-amber-900/80">
                                {
                                  activeRequest.description
                                }
                              </p>

                              {activeRequest.review_notes && (
                                <div className="mt-3 border-t border-amber-200 pt-3">

                                  <p className="text-xs font-semibold uppercase tracking-wide text-amber-700">
                                    Observaciones
                                  </p>

                                  <p className="mt-1 whitespace-pre-wrap text-sm text-amber-900">
                                    {
                                      activeRequest.review_notes
                                    }
                                  </p>

                                </div>
                              )}

                            </div>

                          </div>

                        </div>
                      );
                    }

                    /* ==========================================
                       COMPLETADA
                    ========================================== */

                    if (
                      latestRequest &&
                      normalizeChangeRequestStatus(
                        latestRequest.status
                      ) ===
                        "completed"
                    ) {

                      return (
                        <div className="rounded-xl border border-green-200 bg-green-50 p-5">

                          <div className="flex items-start gap-3">

                            <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-green-600" />

                            <div>

                              <p className="font-semibold text-green-900">
                                Última solicitud completada
                              </p>

                              <p className="mt-1 text-sm text-green-800">
                                El cambio solicitado fue realizado correctamente.
                              </p>

                              <p className="mt-3 whitespace-pre-wrap text-sm text-green-900/80">
                                {
                                  latestRequest.description
                                }
                              </p>

                            </div>

                          </div>

                        </div>
                      );
                    }

                    /* ==========================================
                       RECHAZADA
                    ========================================== */

                    if (
                      latestRequest &&
                      normalizeChangeRequestStatus(
                        latestRequest.status
                      ) ===
                        "rejected"
                    ) {

                      return (
                        <div className="rounded-xl border border-red-200 bg-red-50 p-5">

                          <div className="flex items-start gap-3">

                            <XCircle className="mt-0.5 h-5 w-5 shrink-0 text-red-600" />

                            <div>

                              <p className="font-semibold text-red-900">
                                Última solicitud rechazada
                              </p>

                              <p className="mt-1 text-sm text-red-800">
                                La solicitud fue rechazada por el equipo de Modira.
                              </p>

                              {latestRequest.review_notes && (
                                <div className="mt-3 border-t border-red-200 pt-3">

                                  <p className="text-xs font-semibold uppercase tracking-wide text-red-700">
                                    Motivo
                                  </p>

                                  <p className="mt-1 whitespace-pre-wrap text-sm text-red-900">
                                    {
                                      latestRequest.review_notes
                                    }
                                  </p>

                                </div>
                              )}

                            </div>

                          </div>

                        </div>
                      );
                    }

                    /* ==========================================
                       SIN SOLICITUD
                    ========================================== */

                    return (
                      <div className="rounded-xl border border-[#E8ECF2] bg-[#FAFBFD] p-5">

                        <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">

                          <div>

                            <p className="font-semibold text-[#182230]">
                              ¿Necesitas realizar algún cambio?
                            </p>

                            {selectedProject.change_requests_enabled &&
                            selectedProject.change_requests_deadline ? (

                              <p className="mt-1 text-sm text-[#52627A]">

                                Puedes solicitar cambios hasta el{" "}

                                <strong>
                                  {formatDateTime(
                                    selectedProject.change_requests_deadline
                                  )}
                                </strong>

                                .

                              </p>

                            ) : (

                              <p className="mt-1 text-sm text-[#7B8798]">
                                Actualmente no hay un periodo de solicitudes abierto para este proyecto.
                              </p>

                            )}

                          </div>

                          <Button
                            type="button"
                            disabled={
                              !canRequestChanges(
                                selectedProject
                              )
                            }
                            onClick={() =>
                              handleOpenChangeRequest(
                                selectedProject
                              )
                            }
                            className="shrink-0 gap-2 bg-[#173B8F] text-white hover:bg-[#102A66]"
                          >

                            <MessageSquare className="h-4 w-4" />

                            Solicitar cambio

                          </Button>

                        </div>

                        {!canRequestChanges(
                          selectedProject
                        ) &&
                          selectedProject.change_requests_enabled &&
                          selectedProject.change_requests_deadline &&
                          new Date(
                            selectedProject.change_requests_deadline
                          ) <
                            new Date() && (

                            <div className="mt-4 flex items-start gap-2 rounded-lg border border-red-100 bg-red-50 p-3">

                              <Clock className="mt-0.5 h-4 w-4 shrink-0 text-red-600" />

                              <p className="text-xs text-red-700">
                                El plazo para solicitar cambios ha finalizado.
                              </p>

                            </div>

                          )}

                      </div>
                    );

                  })()}

                </section>

              </div>

              {/* ==================================================
                  FOOTER
              ================================================== */}

              <div className="flex flex-col-reverse gap-3 border-t border-[#E8ECF2] bg-[#FAFBFD] px-6 py-4 sm:flex-row sm:justify-end">

                <Button
                  type="button"
                  variant="outline"
                  onClick={
                    handleCloseProject
                  }
                >
                  Cerrar
                </Button>

                {canRequestChanges(
                  selectedProject
                ) && (
                  <Button
                    type="button"
                    onClick={() =>
                      handleOpenChangeRequest(
                        selectedProject
                      )
                    }
                    className="gap-2 bg-[#173B8F] text-white hover:bg-[#102A66]"
                  >

                    <MessageSquare className="h-4 w-4" />

                    Solicitar cambio

                  </Button>
                )}

              </div>

            </>
          )}

        </DialogContent>

      </Dialog>

      {/* ========================================================
          MODAL SOLICITAR CAMBIO

          ESTE ES UN DIALOGO INDEPENDIENTE.
          NO ESTÁ ANIDADO DENTRO DEL MODAL DE PROYECTO.
      ======================================================== */}

      <Dialog
        open={
          isChangeRequestDialogOpen
        }
        onOpenChange={(
          open
        ) => {
          if (!open) {
            handleCloseChangeRequest();
          }
        }}
      >

        <DialogContent className="sm:max-w-lg">

          <DialogHeader>

            <DialogTitle>
              Solicitar cambio en el proyecto
            </DialogTitle>

            <DialogDescription>
              Describe de forma clara qué modificación necesitas realizar. La solicitud será revisada por el equipo de Modira.
            </DialogDescription>

          </DialogHeader>

          {changeRequestProject && (

            <div className="space-y-5">

              <div className="rounded-xl border border-[#E8ECF2] bg-[#FAFBFD] p-4">

                <p className="text-xs font-semibold uppercase tracking-wide text-[#7B8798]">
                  Proyecto
                </p>

                <p className="mt-1 font-semibold text-[#102A66]">
                  {
                    changeRequestProject.nombre
                  }
                </p>

                {changeRequestProject.change_requests_deadline && (
                  <p className="mt-1 text-xs text-[#52627A]">

                    Puedes solicitar cambios hasta el{" "}

                    <strong>
                      {formatDateTime(
                        changeRequestProject.change_requests_deadline
                      )}
                    </strong>

                    .

                  </p>
                )}

              </div>

              <div className="space-y-2">

                <Label htmlFor="change-request-description">
                  Describe el cambio
                </Label>

                <Textarea
                  id="change-request-description"
                  value={
                    changeRequestDescription
                  }
                  onChange={(event) =>
                    setChangeRequestDescription(
                      event.target.value
                    )
                  }
                  placeholder="Explica qué quieres modificar, añadir o corregir..."
                  rows={7}
                  maxLength={5000}
                  disabled={
                    submittingChangeRequest
                  }
                />

                <div className="flex justify-end">

                  <span className="text-xs text-[#7B8798]">
                    {
                      changeRequestDescription.length
                    }
                    /5000
                  </span>

                </div>

              </div>

              <div className="rounded-lg border border-blue-100 bg-blue-50 p-3">

                <p className="text-xs leading-relaxed text-blue-700">

                  La solicitud no modifica automáticamente
                  el proyecto. El equipo de Modira la revisará
                  y realizará los cambios correspondientes
                  si se acepta.

                </p>

              </div>

            </div>

          )}

          <DialogFooter>

            <Button
              type="button"
              variant="outline"
              onClick={
                handleCloseChangeRequest
              }
              disabled={
                submittingChangeRequest
              }
            >
              Cancelar
            </Button>

            <Button
              type="button"
              onClick={
                handleSubmitChangeRequest
              }
              disabled={
                submittingChangeRequest ||
                !changeRequestDescription.trim()
              }
              className="gap-2 bg-[#173B8F] text-white hover:bg-[#102A66]"
            >

              {submittingChangeRequest ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <MessageSquare className="h-4 w-4" />
              )}

              {submittingChangeRequest
                ? "Enviando..."
                : "Enviar solicitud"}

            </Button>

          </DialogFooter>

        </DialogContent>

      </Dialog>

    </div>
  );
}