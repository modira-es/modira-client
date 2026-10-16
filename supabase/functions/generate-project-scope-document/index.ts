import { createClient } from "npm:@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "npm:pdf-lib@1.17.1";

// ============================================================================
// MODIRA — GENERACIÓN Y PUBLICACIÓN DEL DOCUMENTO OFICIAL DE ALCANCE
// Compatible con la migración 163_project_scope_approval.sql
//
// Request (POST):
//   { "action": "generate_project_scope_document", "version_id": "<uuid>" }
// Aliases accepted:
//   generate_project_scope_version_document
//   generate_scope_document
//
// Flujo:
// 1. Valida JWT de Supabase.
// 2. Verifica que el usuario sea trabajador activo con projects.read y
//    projects.update.
// 3. Lee un borrador de project_scope_versions y su proyecto.
// 4. Genera el PDF en el servidor a partir del snapshot almacenado en DB.
// 5. Lo guarda en el bucket privado project-scope-documents con ruta
//    <project_uuid>/V<version_number>.pdf (sin sobrescribir documentos).
// 6. Calcula SHA-256 de los bytes reales del PDF.
// 7. Llama a publish_project_scope_version() con el JWT del trabajador.
//
// Esta función NO acepta el contenido del alcance desde el cliente. El frontend
// debe guardar el snapshot mediante create_project_scope_draft/update_project_scope_draft
// antes de invocar la generación del PDF.
// ============================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET_NAME = "project-scope-documents";
const MAX_PDF_BYTES = 10 * 1024 * 1024;
const MAX_SNAPSHOT_BYTES = 256 * 1024;
const MAX_RENDER_DEPTH = 8;
const MAX_RENDER_ITEMS = 500;

const A4_WIDTH = 595.28;
const A4_HEIGHT = 841.89;
const MARGIN_X = 48;
const MARGIN_TOP = 54;
const MARGIN_BOTTOM = 48;
const CONTENT_WIDTH = A4_WIDTH - MARGIN_X * 2;

const COLOR_DARK = rgb(0.07, 0.10, 0.18);
const COLOR_MUTED = rgb(0.36, 0.40, 0.47);
const COLOR_ACCENT = rgb(0.06, 0.16, 0.40);
const COLOR_LIGHT = rgb(0.92, 0.94, 0.97);
const COLOR_LINE = rgb(0.82, 0.85, 0.89);
const COLOR_WHITE = rgb(1, 1, 1);

if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error("Faltan SUPABASE_URL, SUPABASE_ANON_KEY o SUPABASE_SERVICE_ROLE_KEY.");
}

const supabaseAdmin = SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
  ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    })
  : null;

function getAllowedOrigins(): Set<string> {
  return new Set(
    (Deno.env.get("MODIRA_ALLOWED_ORIGINS") ?? "")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean),
  );
}

const allowedOrigins = getAllowedOrigins();

function corsHeaders(origin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && allowedOrigins.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  headers: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function safeText(value: unknown, fallback = ""): string {
  if (value === null || value === undefined) return fallback;
  if (typeof value === "string") return value.trim() || fallback;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return fallback;
}

// Standard PDF fonts support WinAnsi, not every Unicode character. Spanish
// characters (á, é, í, ó, ú, ñ, ü, ¿, ¡) are preserved; unsupported glyphs are
// replaced safely instead of causing pdf-lib to fail.
function normalizePdfText(value: unknown): string {
  return safeText(value)
    .replace(/€/g, "EUR")
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .replace(/[–—]/g, "-")
    .replace(/•/g, "- ")
    .replace(/\u00a0/g, " ")
    .replace(/\r/g, "")
    .replace(/[^\x09\x0A\x20-\xFF]/g, "?");
}

function dateTimeEs(value: unknown): string {
  if (!value) return "No indicada";
  const date = new Date(String(value));
  if (Number.isNaN(date.getTime())) return "No indicada";
  return new Intl.DateTimeFormat("es-ES", {
    day: "2-digit", month: "long", year: "numeric",
    hour: "2-digit", minute: "2-digit", timeZone: "Europe/Madrid",
  }).format(date);
}

function dateEs(value: unknown): string {
  if (!value) return "No indicada";
  const date = new Date(String(value));
  if (Number.isNaN(date.getTime())) return "No indicada";
  return new Intl.DateTimeFormat("es-ES", {
    day: "2-digit", month: "long", year: "numeric", timeZone: "Europe/Madrid",
  }).format(date);
}

function sha256Hex(bytes: Uint8Array): Promise<string> {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return crypto.subtle.digest("SHA-256", copy.buffer).then((digest) =>
    Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("")
  );
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  let mismatch = 0;
  for (let i = 0; i < a.byteLength; i++) mismatch |= a[i] ^ b[i];
  return mismatch === 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function titleCaseKey(key: string): string {
  const aliases: Record<string, string> = {
    objetivos: "Objetivos",
    objetivo: "Objetivo",
    descripcion: "Descripción",
    descripcion_proyecto: "Descripción del proyecto",
    resumen: "Resumen",
    alcance_incluido: "Alcance incluido",
    incluido: "Alcance incluido",
    inclusiones: "Alcance incluido",
    alcance_excluido: "Fuera de alcance",
    excluido: "Fuera de alcance",
    exclusiones: "Fuera de alcance",
    fases: "Fases del proyecto",
    entregables: "Entregables",
    criterios_aceptacion: "Criterios de aceptación",
    criterios_de_aceptacion: "Criterios de aceptación",
    dependencias: "Dependencias",
    condiciones: "Condiciones y supuestos",
    supuestos: "Supuestos",
    riesgos: "Riesgos identificados",
    requisitos: "Requisitos",
    limitaciones: "Limitaciones",
    metodologia: "Metodología de trabajo",
    metodologia_trabajo: "Metodología de trabajo",
    responsabilidades_cliente: "Responsabilidades del cliente",
    responsabilidades_modira: "Responsabilidades del proveedor",
    responsabilidades_proveedor: "Responsabilidades del proveedor",
    calendario: "Calendario previsto",
    fechas: "Fechas previstas",
    notas: "Notas adicionales",
    observaciones: "Observaciones",
    precio: "Precio",
    presupuesto: "Presupuesto asociado",
    garantia: "Garantía",
    soporte: "Soporte y mantenimiento",
  };
  const normalized = key.trim().toLowerCase();
  if (aliases[normalized]) return aliases[normalized];
  return key
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/\b\p{L}/gu, (letter) => letter.toLocaleUpperCase("es-ES"));
}

function wrapText(text: string, font: PDFFont, fontSize: number, maxWidth: number): string[] {
  const normalized = normalizePdfText(text).replace(/\s+/g, " ").trim();
  if (!normalized) return [""];
  const words = normalized.split(" ");
  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    const candidate = current ? `${current} ${word}` : word;
    if (font.widthOfTextAtSize(candidate, fontSize) <= maxWidth) {
      current = candidate;
      continue;
    }
    if (current) lines.push(current);
    if (font.widthOfTextAtSize(word, fontSize) <= maxWidth) {
      current = word;
      continue;
    }
    let chunk = "";
    for (const character of word) {
      const candidateChunk = chunk + character;
      if (font.widthOfTextAtSize(candidateChunk, fontSize) > maxWidth && chunk) {
        lines.push(chunk);
        chunk = character;
      } else {
        chunk = candidateChunk;
      }
    }
    current = chunk;
  }
  if (current) lines.push(current);
  return lines;
}

type RenderContext = {
  pdf: PDFDocument;
  page: PDFPage;
  y: number;
  regular: PDFFont;
  bold: PDFFont;
  pageNumber: number;
  totalItems: number;
};

function drawPageFooter(ctx: RenderContext): void {
  ctx.page.drawLine({
    start: { x: MARGIN_X, y: 30 },
    end: { x: A4_WIDTH - MARGIN_X, y: 30 },
    thickness: 0.6,
    color: COLOR_LINE,
  });
  ctx.page.drawText("MODIRA · Documento oficial de alcance", {
    x: MARGIN_X, y: 17, size: 8, font: ctx.regular, color: COLOR_MUTED,
  });
  ctx.page.drawText(`Página ${ctx.pageNumber}`, {
    x: A4_WIDTH - MARGIN_X - 55, y: 17, size: 8, font: ctx.regular, color: COLOR_MUTED,
  });
}

function newPage(ctx: RenderContext): void {
  drawPageFooter(ctx);
  ctx.page = ctx.pdf.addPage([A4_WIDTH, A4_HEIGHT]);
  ctx.pageNumber++;
  ctx.y = A4_HEIGHT - MARGIN_TOP;
}

function ensureSpace(ctx: RenderContext, height: number): void {
  if (ctx.y - height < MARGIN_BOTTOM) newPage(ctx);
}

function drawParagraph(
  ctx: RenderContext,
  text: string,
  options: { font?: PDFFont; size?: number; color?: ReturnType<typeof rgb>; indent?: number; lineGap?: number } = {},
): void {
  const font = options.font ?? ctx.regular;
  const size = options.size ?? 10;
  const color = options.color ?? COLOR_DARK;
  const indent = options.indent ?? 0;
  const lineGap = options.lineGap ?? 4;
  const lines = wrapText(text, font, size, CONTENT_WIDTH - indent);
  const lineHeight = size + lineGap;
  for (const line of lines) {
    ensureSpace(ctx, lineHeight);
    ctx.page.drawText(line, {
      x: MARGIN_X + indent,
      y: ctx.y - size,
      size,
      font,
      color,
      maxWidth: CONTENT_WIDTH - indent,
    });
    ctx.y -= lineHeight;
  }
}

function drawSectionHeading(ctx: RenderContext, title: string): void {
  ensureSpace(ctx, 34);
  ctx.y -= 4;
  ctx.page.drawRectangle({
    x: MARGIN_X,
    y: ctx.y - 20,
    width: CONTENT_WIDTH,
    height: 23,
    color: COLOR_LIGHT,
  });
  ctx.page.drawRectangle({
    x: MARGIN_X,
    y: ctx.y - 20,
    width: 4,
    height: 23,
    color: COLOR_ACCENT,
  });
  ctx.page.drawText(normalizePdfText(title), {
    x: MARGIN_X + 12,
    y: ctx.y - 13,
    size: 11,
    font: ctx.bold,
    color: COLOR_DARK,
  });
  ctx.y -= 31;
}

function primitiveToText(value: unknown): string {
  if (value === null || value === undefined || value === "") return "No especificado";
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  if (Array.isArray(value)) return value.map(primitiveToText).join(", ");
  return JSON.stringify(value);
}

function renderValue(ctx: RenderContext, value: unknown, depth: number, bullet = false): void {
  ctx.totalItems++;
  if (ctx.totalItems > MAX_RENDER_ITEMS) {
    drawParagraph(ctx, "Se ha alcanzado el límite de elementos renderizados del documento.", { size: 9, color: COLOR_MUTED });
    return;
  }
  if (depth > MAX_RENDER_DEPTH) {
    drawParagraph(ctx, "(Se omiten niveles de anidamiento adicionales.)", { size: 9, color: COLOR_MUTED, indent: 12 });
    return;
  }

  if (value === null || value === undefined || value === "") {
    drawParagraph(ctx, bullet ? "- No especificado" : "No especificado", { indent: bullet ? 8 : 0 });
    return;
  }

  if (Array.isArray(value)) {
    if (value.length === 0) {
      drawParagraph(ctx, "No especificado", { color: COLOR_MUTED, indent: 8 });
      return;
    }
    value.forEach((item, index) => {
      if (isRecord(item)) {
        const label = safeText(item.nombre ?? item.titulo ?? item.name ?? item.title, `Elemento ${index + 1}`);
        drawParagraph(ctx, `• ${label}`, { font: ctx.bold, indent: 6 });
        for (const [key, nested] of Object.entries(item)) {
          if (["nombre", "titulo", "name", "title"].includes(key)) continue;
          if (nested === null || nested === undefined || nested === "") continue;
          drawParagraph(ctx, `${titleCaseKey(key)}:`, { font: ctx.bold, size: 9, indent: 18 });
          renderValue(ctx, nested, depth + 1, true);
        }
        ctx.y -= 3;
      } else {
        drawParagraph(ctx, `• ${primitiveToText(item)}`, { indent: 8 });
      }
    });
    return;
  }

  if (isRecord(value)) {
    const entries = Object.entries(value).filter(([, nested]) => nested !== undefined && nested !== null && nested !== "");
    if (entries.length === 0) {
      drawParagraph(ctx, "No especificado", { color: COLOR_MUTED, indent: 8 });
      return;
    }
    for (const [key, nested] of entries) {
      drawParagraph(ctx, `${titleCaseKey(key)}:`, { font: ctx.bold, size: 9.5, indent: 6 });
      renderValue(ctx, nested, depth + 1, true);
    }
    return;
  }

  drawParagraph(ctx, `${bullet ? "• " : ""}${primitiveToText(value)}`, { indent: bullet ? 8 : 0 });
}

function snapshotSections(snapshot: Record<string, unknown>): Array<[string, unknown]> {
  const metadataKeys = new Set([
    "schema_version", "version", "created_at", "updated_at", "project_id", "project_name",
    "nombre_proyecto", "title", "titulo_proyecto",
  ]);
  const entries = Object.entries(snapshot).filter(([key, value]) => !metadataKeys.has(key.toLowerCase()) && value !== undefined);
  const priority = [
    "resumen", "descripcion", "descripcion_proyecto", "objetivos", "alcance_incluido",
    "inclusiones", "alcance_excluido", "exclusiones", "fases", "entregables",
    "criterios_aceptacion", "criterios_de_aceptacion", "dependencias", "condiciones",
    "supuestos", "responsabilidades_cliente", "responsabilidades_proveedor", "responsabilidades_modira",
    "calendario", "fechas", "requisitos", "limitaciones", "riesgos", "metodologia",
    "notas", "observaciones",
  ];
  const rank = (key: string) => {
    const index = priority.indexOf(key.toLowerCase());
    return index === -1 ? priority.length : index;
  };
  return entries.sort(([a], [b]) => rank(a) - rank(b));
}

async function buildScopePdf(
  project: Record<string, unknown>,
  version: Record<string, unknown>,
): Promise<Uint8Array> {
  const snapshot = version.content_snapshot;
  if (!isRecord(snapshot)) throw new Error("El snapshot del alcance no es un objeto JSON válido.");
  const snapshotBytes = new TextEncoder().encode(JSON.stringify(snapshot)).byteLength;
  if (snapshotBytes > MAX_SNAPSHOT_BYTES) throw new Error("El contenido del alcance supera los 256 KiB permitidos.");

  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const fixedDate = new Date(String(version.created_at ?? "2020-01-01T00:00:00.000Z"));
  const validFixedDate = Number.isNaN(fixedDate.getTime()) ? new Date("2020-01-01T00:00:00.000Z") : fixedDate;
  pdf.setTitle(`Documento oficial de alcance - ${safeText(project.nombre, "Proyecto")}`);
  pdf.setSubject(`Alcance del proyecto ${String(project.id)} - versión ${String(version.version_number)}`);
  pdf.setAuthor("Modira");
  pdf.setCreator("Modira - Generador oficial de alcance");
  pdf.setProducer("Modira");
  // Fecha estable para que un reintento de la misma versión pueda comparar bytes.
  pdf.setCreationDate(validFixedDate);
  pdf.setModificationDate(validFixedDate);

  const firstPage = pdf.addPage([A4_WIDTH, A4_HEIGHT]);
  const ctx: RenderContext = {
    pdf,
    page: firstPage,
    y: A4_HEIGHT - MARGIN_TOP,
    regular,
    bold,
    pageNumber: 1,
    totalItems: 0,
  };

  ctx.page.drawRectangle({
    x: 0, y: A4_HEIGHT - 145, width: A4_WIDTH, height: 145, color: COLOR_DARK,
  });
  ctx.page.drawText("MODIRA", {
    x: MARGIN_X, y: A4_HEIGHT - 62, size: 12, font: bold, color: COLOR_WHITE,
  });
  ctx.page.drawText("DOCUMENTO OFICIAL DE ALCANCE", {
    x: MARGIN_X, y: A4_HEIGHT - 91, size: 19, font: bold, color: COLOR_WHITE,
  });
  ctx.page.drawText(`Versión ${String(version.version_number)}`, {
    x: MARGIN_X, y: A4_HEIGHT - 119, size: 11, font: regular, color: COLOR_WHITE,
  });
  ctx.y = A4_HEIGHT - 178;

  drawParagraph(ctx, safeText(project.nombre, "Proyecto sin nombre"), { font: bold, size: 16, color: COLOR_DARK, lineGap: 6 });
  ctx.y -= 5;
  drawParagraph(ctx, `Identificador del proyecto: ${safeText(project.id)}`, { size: 8.5, color: COLOR_MUTED });
  drawParagraph(ctx, `Estado actual: ${safeText(project.estado, "Pendiente")}`, { size: 8.5, color: COLOR_MUTED });
  drawParagraph(ctx, `Fecha de inicio prevista: ${dateEs(project.fecha_inicio)}`, { size: 8.5, color: COLOR_MUTED });
  drawParagraph(ctx, `Fecha de fin prevista: ${dateEs(project.fecha_fin)}`, { size: 8.5, color: COLOR_MUTED });
  drawParagraph(ctx, `Versión creada: ${dateTimeEs(version.created_at)}`, { size: 8.5, color: COLOR_MUTED });

  if (safeText(project.descripcion)) {
    ctx.y -= 7;
    drawSectionHeading(ctx, "Descripción general del proyecto");
    drawParagraph(ctx, safeText(project.descripcion), { size: 10.2, lineGap: 5 });
  }

  const sections = snapshotSections(snapshot);
  if (sections.length === 0) {
    ctx.y -= 7;
    drawSectionHeading(ctx, "Contenido del alcance");
    drawParagraph(ctx, "El borrador no contiene apartados definidos.", { color: COLOR_MUTED });
  } else {
    for (const [key, value] of sections) {
      ctx.y -= 7;
      drawSectionHeading(ctx, titleCaseKey(key));
      renderValue(ctx, value, 0);
    }
  }

  ctx.y -= 8;
  drawSectionHeading(ctx, "Control documental");
  drawParagraph(ctx, "Este PDF representa el snapshot del alcance almacenado en Modira para la versión indicada. La aceptación del cliente se registra de forma separada e identifica esta versión y la huella SHA-256 del documento.", { size: 9, lineGap: 4 });
  drawParagraph(ctx, "El documento no acredita por sí solo la aceptación del cliente. La aceptación solo existe cuando queda registrada en la plataforma.", { size: 9, lineGap: 4, color: COLOR_MUTED });

  drawPageFooter(ctx);
  const bytes = await pdf.save({ useObjectStreams: false });
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_PDF_BYTES) {
    throw new Error("El PDF generado está vacío o supera el límite de 10 MiB.");
  }
  return bytes;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("Origin");
  const headers = corsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers });
  }
  if (req.method !== "POST") {
    return jsonResponse({ success: false, error: "Método no permitido. Usa POST." }, 405, headers);
  }
  if (origin && !allowedOrigins.has(origin)) {
    return jsonResponse({ success: false, error: "Origen no autorizado." }, 403, headers);
  }
  if (allowedOrigins.size === 0) {
    return jsonResponse({ success: false, error: "MODIRA_ALLOWED_ORIGINS no está configurada." }, 500, headers);
  }
  if (!supabaseAdmin || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return jsonResponse({ success: false, error: "Falta configuración de Supabase en la Edge Function." }, 500, headers);
  }

  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization || !/^Bearer\s+\S+$/i.test(authorization)) {
      return jsonResponse({ success: false, error: "Falta una sesión autenticada." }, 401, headers);
    }

    const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authorization } },
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });

    const { data: userData, error: userError } = await supabaseUser.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse({ success: false, error: "La sesión no es válida o ha caducado." }, 401, headers);
    }

    const { data: isWorker, error: workerError } = await supabaseUser.rpc("current_user_is_worker");
    if (workerError) {
      console.error("No se pudo verificar el rol de trabajador:", workerError.message);
      return jsonResponse({ success: false, error: "No se ha podido verificar el rol del usuario." }, 500, headers);
    }
    if (isWorker !== true) {
      return jsonResponse({ success: false, error: "Acceso denegado: se requiere un trabajador activo." }, 403, headers);
    }

    const permissions = await Promise.all([
      supabaseUser.rpc("current_worker_has_permission", { p_permission_code: "projects.read" }),
      supabaseUser.rpc("current_worker_has_permission", { p_permission_code: "projects.update" }),
    ]);
    const permissionError = permissions.find((result) => result.error);
    if (permissionError?.error) {
      console.error("Error verificando permisos:", permissionError.error.message);
      return jsonResponse({ success: false, error: "No se han podido verificar los permisos del trabajador." }, 500, headers);
    }
    if (permissions.some((result) => result.data !== true)) {
      return jsonResponse({ success: false, error: "Acceso denegado: se requieren los permisos projects.read y projects.update." }, 403, headers);
    }

    let body: unknown;
    try {
      const contentLength = Number(req.headers.get("Content-Length") ?? 0);
      if (contentLength > 16 * 1024) {
        return jsonResponse({ success: false, error: "La petición supera el tamaño permitido." }, 413, headers);
      }
      body = await req.json();
    } catch {
      return jsonResponse({ success: false, error: "El cuerpo de la petición debe ser JSON válido." }, 400, headers);
    }
    if (!isRecord(body)) {
      return jsonResponse({ success: false, error: "El cuerpo de la petición debe ser un objeto JSON." }, 400, headers);
    }

    const action = safeText(body.action);
    if (![
      "generate_project_scope_document",
      "generate_project_scope_version_document",
      "generate_scope_document",
    ].includes(action)) {
      return jsonResponse({
        success: false,
        error: "Acción no válida. Usa generate_project_scope_document.",
      }, 400, headers);
    }

    const versionId = safeText(body.version_id ?? body.versionId);
    if (!versionId || !isUuid(versionId)) {
      return jsonResponse({ success: false, error: "version_id debe ser un UUID válido." }, 400, headers);
    }

    // El usuario autenticado consulta el borrador sujeto a RLS; el service role
    // se reserva para Storage, no para decidir si el trabajador puede publicar.
    const { data: version, error: versionError } = await supabaseUser
      .from("project_scope_versions")
      .select("id, project_id, version_number, status, content_snapshot, is_current, created_by, created_at, published_at, document_path, document_sha256")
      .eq("id", versionId)
      .maybeSingle();

    if (versionError) {
      console.error("Error leyendo versión del alcance:", versionError.message);
      return jsonResponse({ success: false, error: "No se ha podido consultar el borrador del alcance." }, 500, headers);
    }
    if (!version) {
      return jsonResponse({ success: false, error: "El borrador no existe o no tienes permiso para consultarlo." }, 404, headers);
    }

    // Idempotencia: si ya está publicado, no regenerar ni sobrescribir el PDF.
    if (version.published_at && version.document_path && version.document_sha256) {
      return jsonResponse({
        success: true,
        mode: "project_scope_pdf",
        project_id: version.project_id,
        version_id: version.id,
        version_number: version.version_number,
        document_path: version.document_path,
        document_sha256: version.document_sha256,
        already_published: true,
      }, 200, headers);
    }

    if (version.status !== "draft" || version.published_at) {
      return jsonResponse({ success: false, error: "Solo se pueden publicar borradores no publicados." }, 409, headers);
    }
    if (!isRecord(version.content_snapshot)) {
      return jsonResponse({ success: false, error: "El snapshot del alcance no es un objeto JSON válido." }, 422, headers);
    }

    const { data: project, error: projectError } = await supabaseUser
      .from("projects")
      .select("id, nombre, descripcion, estado, fecha_inicio, fecha_fin, user_id, company_id, client_id")
      .eq("id", version.project_id)
      .maybeSingle();

    if (projectError) {
      console.error("Error leyendo proyecto del alcance:", projectError.message);
      return jsonResponse({ success: false, error: "No se ha podido consultar el proyecto asociado." }, 500, headers);
    }
    if (!project) {
      return jsonResponse({ success: false, error: "El proyecto no existe o no tienes permiso para consultarlo." }, 404, headers);
    }
    if (["Entregado", "Completado"].includes(String(project.estado))) {
      return jsonResponse({ success: false, error: "No se puede publicar el alcance de un proyecto finalizado." }, 409, headers);
    }

    const documentPath = `${String(project.id)}/V${Number(version.version_number)}.pdf`;
    if (!Number.isInteger(Number(version.version_number)) || Number(version.version_number) < 1) {
      return jsonResponse({ success: false, error: "El número de versión almacenado no es válido." }, 500, headers);
    }

    const pdfBytes = await buildScopePdf(project as Record<string, unknown>, version as Record<string, unknown>);
    const documentSha256 = await sha256Hex(pdfBytes);

    // Intento sin upsert: un PDF publicado o un objeto huérfano nunca se pisa
    // silenciosamente. Si el objeto existe, se compara byte a byte con el PDF
    // determinista generado a partir del borrador actual.
    const { error: uploadError } = await supabaseAdmin.storage
      .from(BUCKET_NAME)
      .upload(documentPath, pdfBytes, {
        contentType: "application/pdf",
        cacheControl: "3600",
        upsert: false,
      });

    let finalHash = documentSha256;
    if (uploadError) {
      const message = uploadError.message.toLowerCase();
      const looksLikeExists = message.includes("already exists") || message.includes("duplicate") || message.includes("resource already exists") || message.includes("409");
      if (!looksLikeExists) {
        console.error("Error subiendo PDF de alcance:", uploadError.message);
        return jsonResponse({ success: false, error: "No se ha podido guardar el PDF oficial del alcance." }, 502, headers);
      }

      const { data: existingBlob, error: downloadError } = await supabaseAdmin.storage
        .from(BUCKET_NAME)
        .download(documentPath);
      if (downloadError || !existingBlob) {
        console.error("Existe un objeto para esta versión, pero no se pudo verificar:", downloadError?.message);
        return jsonResponse({ success: false, error: "Ya existe un archivo para esta versión y no se ha podido verificar. No se ha sobrescrito." }, 409, headers);
      }
      const existingBytes = new Uint8Array(await existingBlob.arrayBuffer());
      if (!bytesEqual(existingBytes, pdfBytes)) {
        return jsonResponse({
          success: false,
          error: "Ya existe un PDF diferente para esta versión no publicada. No se ha sobrescrito para proteger la integridad documental. Elimina el objeto huérfano de Storage tras verificar que la versión sigue en borrador y vuelve a intentarlo.",
        }, 409, headers);
      }
      finalHash = await sha256Hex(existingBytes);
    }

    // La publicación se hace con el JWT del trabajador, no con service_role,
    // para que publish_project_scope_version aplique sus comprobaciones RBAC.
    const { data: published, error: publishError } = await supabaseUser.rpc(
      "publish_project_scope_version",
      {
        p_version_id: versionId,
        p_document_path: documentPath,
        p_document_sha256: finalHash,
      },
    );

    if (publishError) {
      console.error("Error publicando versión del alcance:", publishError.message);
      // No se borra automáticamente el objeto: si la respuesta de red se perdió
      // después del commit, borrarlo podría destruir el PDF oficial ya publicado.
      return jsonResponse({
        success: false,
        error: "El PDF se ha generado y guardado, pero la publicación en la base de datos ha fallado. No vuelvas a subir otro archivo; reintenta la misma operación o revisa el error devuelto.",
        details: publishError.message,
        document_path: documentPath,
        document_sha256: finalHash,
      }, 502, headers);
    }

    return jsonResponse({
      success: true,
      mode: "project_scope_pdf",
      project_id: project.id,
      version_id: versionId,
      version_number: version.version_number,
      document_path: documentPath,
      document_sha256: finalHash,
      already_published: false,
      version: published,
    }, 200, headers);
  } catch (error) {
    console.error("Error inesperado en generate-project-scope-document:", error);
    const message = error instanceof Error ? error.message : "Error inesperado";
    return jsonResponse({ success: false, error: message }, 500, headers);
  }
});
