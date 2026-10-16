import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2";

import {
  PDFDocument,
  StandardFonts,
  rgb,
} from "npm:pdf-lib@1.17.1";

// ============================================================
// MODIRA — QUOTATION DOCUMENT
// ============================================================
//
// Flujo:
//
// Worker autenticado
//      ↓
// Edge Function
//      ↓
// obtiene quotation desde DB
//      ↓
// genera PDF oficial server-side
//      ↓
// sube quotations/<company_id>/<numero_presupuesto>.pdf
//      ↓
// calcula SHA-256 del PDF real
//      ↓
// finalize_quotation_backend_document()
//      ↓
// quotations.document_path
// quotations.document_sha256
//
// Los importes y datos fiscales NO vienen del frontend.
// Se toman exclusivamente de quotations y de sus snapshots.
//
// ============================================================

// ============================================================
// SUPABASE
// ============================================================

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
const supabaseServiceRoleKey = Deno.env.get(
  "SUPABASE_SERVICE_ROLE_KEY",
);

if (!supabaseUrl) {
  throw new Error("SUPABASE_URL no está configurada");
}

if (!supabaseAnonKey) {
  throw new Error("SUPABASE_ANON_KEY no está configurada");
}

if (!supabaseServiceRoleKey) {
  throw new Error(
    "SUPABASE_SERVICE_ROLE_KEY no está configurada",
  );
}

// Cliente service_role.
// Solo se utiliza para consultar datos necesarios del presupuesto,
// generar/guardar el PDF y ejecutar la RPC backend de finalización.
const supabaseAdmin = createClient(
  supabaseUrl,
  supabaseServiceRoleKey,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  },
);

// ============================================================
// CORS
// ============================================================

function getAllowedOrigins(): Set<string> {
  const raw =
    Deno.env.get("MODIRA_ALLOWED_ORIGINS") ?? "";

  const origins = raw
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);

  if (origins.length === 0) {
    throw new Error(
      "MODIRA_ALLOWED_ORIGINS no está configurada.",
    );
  }

  return new Set(origins);
}

const allowedOrigins = getAllowedOrigins();

function getCorsHeaders(origin: string | null) {
  const allowed =
    origin !== null &&
    allowedOrigins.has(origin);

  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods":
      "POST, OPTIONS",
    "Vary": "Origin",
  };

  if (allowed && origin) {
    headers["Access-Control-Allow-Origin"] = origin;
  }

  return headers;
}

// ============================================================
// CONSTANTES
// ============================================================

const BUCKET_NAME = "quotations";
const MAX_FILE_SIZE = 20 * 1024 * 1024;

const A4_WIDTH = 595.28;
const A4_HEIGHT = 841.89;

const MARGIN_X = 48;
const MARGIN_TOP = 48;

// Espacio reservado para el contenido del presupuesto.
const MARGIN_BOTTOM = 160;

// Posición independiente del pie de página existente.
const FOOTER_BOTTOM = 48;

const DARK = rgb(0.07, 0.10, 0.18);
const MUTED = rgb(0.38, 0.41, 0.47);
const LIGHT = rgb(0.92, 0.93, 0.95);
const WHITE = rgb(1, 1, 1);
const ACCENT = rgb(0.06, 0.16, 0.40);

// ============================================================
// UTILIDADES GENERALES
// ============================================================

function safeText(
  value: unknown,
  fallback = "",
): string {
  const text = String(value ?? "").trim();
  return text || fallback;
}

function normalizePdfText(value: unknown): string {
  return safeText(value)
    .replace(/€/g, "EUR")
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .replace(/–|—/g, "-")
    .replace(/•/g, "-")
    .replace(/[^\x00-\xFF]/g, "?");
}

function money(value: unknown): string {
  const amount = Number(value ?? 0);

  if (!Number.isFinite(amount)) {
    return "0,00 EUR";
  }

  return (
    new Intl.NumberFormat("es-ES", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(amount) + " EUR"
  );
}

function percentage(value: unknown): string {
  const amount = Number(value ?? 0);

  if (!Number.isFinite(amount)) {
    return "0,00 %";
  }

  return (
    new Intl.NumberFormat("es-ES", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(amount) + " %"
  );
}

function dateEs(value: unknown): string {
  if (!value) {
    return "-";
  }

  const date = new Date(String(value));

  if (Number.isNaN(date.getTime())) {
    return "-";
  }

  return new Intl.DateTimeFormat("es-ES", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(date);
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((byte) =>
      byte.toString(16).padStart(2, "0"),
    )
    .join("");
}

async function calculateSha256(
  data: ArrayBuffer,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    data,
  );

  return bytesToHex(
    new Uint8Array(digest),
  );
}
// ============================================================
// GENERAR PDF FIRMADO DEL PRESUPUESTO
// ============================================================

async function generateSignedQuotationPdf(
  originalPdfBytes: Uint8Array,
  signaturePngBytes: Uint8Array,
  signerName: string,
): Promise<Uint8Array> {
  if (
    originalPdfBytes.byteLength === 0 ||
    originalPdfBytes.byteLength > MAX_FILE_SIZE
  ) {
    throw new Error("El PDF original está vacío o supera el tamaño permitido");
  }

  if (
    signaturePngBytes.byteLength === 0 ||
    signaturePngBytes.byteLength > 1024 * 1024
  ) {
    throw new Error("La imagen de la firma está vacía o supera 1 MiB");
  }

  const pdf = await PDFDocument.load(originalPdfBytes, {
    updateMetadata: false,
  });

  const signature = await pdf.embedPng(signaturePngBytes);

  const pages = pdf.getPages();

  if (pages.length === 0) {
    throw new Error("El PDF original no contiene páginas");
  }

  // ----------------------------------------------------------
  // FIRMA ELECTRÓNICA EN LA FRANJA INFERIOR
  // ----------------------------------------------------------

  const signatureWidth = 170;
  const signatureHeight =
    (signature.height / signature.width) * signatureWidth;

  if (signatureHeight > 60) {
    throw new Error(
      "La imagen de la firma tiene proporciones no válidas",
    );
  }

  const regularFont = await pdf.embedFont(
    StandardFonts.Helvetica,
  );

  const boldFont = await pdf.embedFont(
    StandardFonts.HelveticaBold,
  );

  for (const page of pages) {
    const { width, height } = page.getSize();

    if (width < signatureWidth + 96 || height < 200) {
      throw new Error(
        "El tamaño de página no permite colocar la firma",
      );
    }

    // Limpiar la franja inferior del PDF original.
    // El pie de página queda fuera de esta zona.
    page.drawRectangle({
      x: 0,
      y: 48,
      width,
      height: 140,
      color: WHITE,
      borderWidth: 0,
    });

    // Separación entre el contenido y la franja de firma.
    page.drawLine({
      start: {
        x: MARGIN_X,
        y: 188,
      },
      end: {
        x: width - MARGIN_X,
        y: 188,
      },
      thickness: 0.7,
      color: LIGHT,
    });

    // Nombre del usuario autenticado, alineado a la derecha.
    const signerLabel = normalizePdfText(
      `Firmado por: ${signerName}`,
    );

    const signerLabelWidth = boldFont.widthOfTextAtSize(
      signerLabel,
      8.5,
    );

    page.drawText(signerLabel, {
      x: width - MARGIN_X - signerLabelWidth,
      y: 151,
      size: 8.5,
      font: boldFont,
      color: DARK,
    });

    // Imagen de la firma debajo del nombre,
    // alineada con el margen derecho.
    page.drawImage(signature, {
      x: width - MARGIN_X - signatureWidth,
      y: 65,
      width: signatureWidth,
      height: signatureHeight,
    });
  }

  const signedBytes = await pdf.save();

  if (
    signedBytes.byteLength === 0 ||
    signedBytes.byteLength > MAX_FILE_SIZE
  ) {
    throw new Error("El PDF firmado está vacío o supera el tamaño permitido");
  }

  return signedBytes;
}

function toArrayBuffer(
  bytes: Uint8Array,
): ArrayBuffer {
  const buffer = new ArrayBuffer(
    bytes.byteLength,
  );

  new Uint8Array(buffer).set(bytes);

  return buffer;
}

function wrapText(
  text: string,
  font: any,
  fontSize: number,
  maxWidth: number,
): string[] {
  const normalized = normalizePdfText(text);

  if (!normalized) {
    return [""];
  }

  const words = normalized.split(/\s+/);
  const lines: string[] = [];
  let current = "";

  for (const word of words) {
    const candidate = current
      ? `${current} ${word}`
      : word;

    if (
      font.widthOfTextAtSize(
        candidate,
        fontSize,
      ) <= maxWidth
    ) {
      current = candidate;
      continue;
    }

    if (current) {
      lines.push(current);
    }

    if (
      font.widthOfTextAtSize(
        word,
        fontSize,
      ) <= maxWidth
    ) {
      current = word;
      continue;
    }

    let chunk = "";

    for (const char of word) {
      const candidateChunk = chunk + char;

      if (
        font.widthOfTextAtSize(
          candidateChunk,
          fontSize,
        ) <= maxWidth
      ) {
        chunk = candidateChunk;
      } else {
        if (chunk) {
          lines.push(chunk);
        }

        chunk = char;
      }
    }

    current = chunk;
  }

  if (current) {
    lines.push(current);
  }

  return lines.length > 0
    ? lines
    : [""];
}

function drawLabelValue(
  page: any,
  label: string,
  value: string,
  x: number,
  y: number,
  width: number,
  font: any,
  boldFont: any,
) {
  page.drawText(
    normalizePdfText(label),
    {
      x,
      y,
      size: 8,
      font,
      color: MUTED,
    },
  );

  const lines = wrapText(
    value,
    font,
    9,
    width,
  );

  let currentY = y - 13;

  for (const line of lines.slice(0, 4)) {
    page.drawText(
      normalizePdfText(line),
      {
        x,
        y: currentY,
        size: 9,
        font: boldFont,
        color: DARK,
      },
    );

    currentY -= 11;
  }

  return currentY;
}

function drawSectionTitle(
  page: any,
  title: string,
  x: number,
  y: number,
  width: number,
  boldFont: any,
) {
  page.drawText(
    normalizePdfText(title),
    {
      x,
      y,
      size: 10,
      font: boldFont,
      color: DARK,
    },
  );

  page.drawLine({
    start: {
      x,
      y: y - 7,
    },
    end: {
      x: x + width,
      y: y - 7,
    },
    thickness: 0.7,
    color: LIGHT,
  });

  return y - 23;
}

function parseServices(
  value: unknown,
): Array<{
  descripcion: string;
  cantidad: number;
  precio: number;
}> {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((raw) => {
    const service =
      raw &&
      typeof raw === "object"
        ? raw as Record<string, unknown>
        : {};

    const quantity = Number(
      service.cantidad ?? 0,
    );

    const price = Number(
      service.precio ?? 0,
    );

    return {
      descripcion: safeText(
        service.descripcion,
        "Servicio",
      ),
      cantidad:
        Number.isFinite(quantity)
          ? quantity
          : 0,
      precio:
        Number.isFinite(price)
          ? price
          : 0,
    };
  });
}
// ============================================================
// ALCANCE DEL PROYECTO — UTILIDADES PARA EL PDF
// ============================================================

const SCOPE_FIELD_LABELS: Record<string, string> = {
  schema_version: "Versión del esquema",
  resumen: "Resumen del alcance",
  objetivos: "Objetivos",
  alcance_incluido: "Alcance incluido",
  inclusiones: "Inclusiones",
  alcance_excluido: "Alcance excluido",
  exclusiones: "Exclusiones",
  fases: "Fases del proyecto",
  entregables: "Entregables",
  criterios_aceptacion: "Criterios de aceptación",
  criterios_de_aceptacion: "Criterios de aceptación",
  dependencias: "Dependencias",
  condiciones: "Condiciones y supuestos",
  supuestos: "Supuestos",
  responsabilidades_cliente: "Responsabilidades del cliente",
  responsabilidades_modira: "Responsabilidades de Modira",
  responsabilidades_proveedor: "Responsabilidades del proveedor",
  calendario: "Calendario",
  fechas: "Fechas",
  requisitos: "Requisitos",
  limitaciones: "Limitaciones",
  riesgos: "Riesgos",
  metodologia: "Metodología",
  notas: "Notas del alcance",
  observaciones: "Observaciones",
  descripcion: "Descripción",
  descripcion_proyecto: "Descripción del proyecto",
  titulo_proyecto: "Título del proyecto",
  nombre_proyecto: "Nombre del proyecto",
  project_name: "Nombre del proyecto",
};

function scopeFieldLabel(key: string): string {
  const knownLabel = SCOPE_FIELD_LABELS[key.toLowerCase()];

  if (knownLabel) {
    return knownLabel;
  }

  return key
    .replace(/_/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^./, (character) => character.toUpperCase());
}

function isScopeValuePresent(value: unknown): boolean {
  if (value === null || value === undefined) {
    return false;
  }

  if (typeof value === "string") {
    return value.trim().length > 0;
  }

  if (typeof value === "number") {
    return Number.isFinite(value);
  }

  if (typeof value === "boolean") {
    return true;
  }

  if (Array.isArray(value)) {
    return value.some(isScopeValuePresent);
  }

  if (typeof value === "object") {
    return Object.values(
      value as Record<string, unknown>,
    ).some(isScopeValuePresent);
  }

  return false;
}

function scopeValueToText(value: unknown): string {
  if (value === null || value === undefined) {
    return "";
  }

  if (typeof value === "string") {
    return value.trim();
  }

  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }

  if (Array.isArray(value)) {
    return value
      .filter(isScopeValuePresent)
      .map((item, index) => {
        if (
          item !== null &&
          typeof item === "object" &&
          !Array.isArray(item)
        ) {
          const objectValue = item as Record<string, unknown>;

          const fields = Object.entries(objectValue)
            .filter(([, fieldValue]) =>
              isScopeValuePresent(fieldValue),
            )
            .map(([key, fieldValue]) => {
              return `${scopeFieldLabel(key)}: ${scopeValueToText(fieldValue)}`;
            });

          return fields.length > 0
            ? `Elemento ${index + 1}\n${fields.join("\n")}`
            : "";
        }

        return `• ${scopeValueToText(item)}`;
      })
      .filter(Boolean)
      .join("\n");
  }

  if (typeof value === "object") {
    const objectValue = value as Record<string, unknown>;

    return Object.entries(objectValue)
      .filter(([, fieldValue]) =>
        isScopeValuePresent(fieldValue),
      )
      .map(([key, fieldValue]) => {
        return `${scopeFieldLabel(key)}: ${scopeValueToText(fieldValue)}`;
      })
      .filter(Boolean)
      .join("\n");
  }

  return "";
}

function getQuotationScopeFields(
  quotation: Record<string, any>,
): Array<{ label: string; value: string }> {
  const snapshot = quotation.project_scope_snapshot;

  if (
    !snapshot ||
    typeof snapshot !== "object" ||
    Array.isArray(snapshot)
  ) {
    return [];
  }

  const metadataKeys = new Set([
    "project_id",
    "project_name",
    "nombre_proyecto",
    "created_at",
    "updated_at",
    "schema_version",
  ]);

  return Object.entries(
    snapshot as Record<string, unknown>,
  )
    .filter(([key, value]) => {
      return (
        !metadataKeys.has(key.toLowerCase()) &&
        isScopeValuePresent(value)
      );
    })
    .map(([key, value]) => ({
      label: scopeFieldLabel(key),
      value: scopeValueToText(value),
    }))
    .filter((field) => field.value.length > 0);
}
// ============================================================
// PDF — GENERACIÓN OFICIAL DEL PRESUPUESTO
// ============================================================

async function generateQuotationPdf(
  quotation: Record<string, any>,
  versionLabel?: string,
): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();

  const quotationNumber =
    normalizePdfText(
      safeText(
        quotation.numero_presupuesto,
        "-",
      ),
    );

  const normalizedVersionLabel = versionLabel
    ? normalizePdfText(versionLabel)
    : "";

  pdf.setTitle(
    normalizedVersionLabel
      ? `Presupuesto ${quotationNumber} - ${normalizedVersionLabel}`
      : `Presupuesto ${quotationNumber}`,
  );

  pdf.setAuthor("Modira");
  pdf.setSubject(
    "Presupuesto emitido por Modira",
  );
  pdf.setCreator("Modira");
  pdf.setProducer("Modira");

  // Las versiones oficiales deben producir los mismos bytes al reintentarse.
  // Usamos una fecha estable del snapshot para que el hash no cambie por la
  // hora en la que se ejecuta la Edge Function. El flujo legacy no se altera.
  if (versionLabel) {
    const snapshotDate = new Date(
      String(
        quotation.fecha_emision ??
        quotation.created_at ??
        "1970-01-01T00:00:00.000Z"
      ),
    );
    const stableDate = Number.isNaN(snapshotDate.getTime())
      ? new Date("1970-01-01T00:00:00.000Z")
      : snapshotDate;
    pdf.setCreationDate(stableDate);
    pdf.setModificationDate(stableDate);
  }

  const regularFont =
    await pdf.embedFont(
      StandardFonts.Helvetica,
    );

  const boldFont =
    await pdf.embedFont(
      StandardFonts.HelveticaBold,
    );

  let page = pdf.addPage([
    A4_WIDTH,
    A4_HEIGHT,
  ]);

  let y =
    A4_HEIGHT - MARGIN_TOP;

  const contentWidth =
    A4_WIDTH - MARGIN_X * 2;

  // ----------------------------------------------------------
  // CABECERA
  // ----------------------------------------------------------

  page.drawText("MODIRA", {
    x: MARGIN_X,
    y,
    size: 22,
    font: boldFont,
    color: ACCENT,
  });

  page.drawText("PRESUPUESTO", {
    x: MARGIN_X,
    y: y - 28,
    size: 15,
    font: boldFont,
    color: DARK,
  });

  if (normalizedVersionLabel) {
    page.drawText(`Versión ${normalizedVersionLabel}`, {
      x: MARGIN_X,
      y: y - 44,
      size: 9,
      font: boldFont,
      color: ACCENT,
    });
  }

  const numberWidth =
    boldFont.widthOfTextAtSize(
      quotationNumber,
      11,
    );

  page.drawText(
    quotationNumber,
    {
      x:
        A4_WIDTH -
        MARGIN_X -
        numberWidth,
      y,
      size: 11,
      font: boldFont,
      color: DARK,
    },
  );

  page.drawText(
    `Emisión: ${dateEs(quotation.fecha_emision)}`,
    {
      x:
        A4_WIDTH -
        MARGIN_X -
        150,
      y: y - 18,
      size: 8.5,
      font: regularFont,
      color: MUTED,
    },
  );

  page.drawText(
    `Validez: ${dateEs(quotation.fecha_validez)}`,
    {
      x:
        A4_WIDTH -
        MARGIN_X -
        150,
      y: y - 31,
      size: 8.5,
      font: regularFont,
      color: MUTED,
    },
  );

  y -= 72;

  // ----------------------------------------------------------
  // DATOS FISCALES
  // ----------------------------------------------------------

  const columnGap = 24;

  const columnWidth =
    (contentWidth - columnGap) / 2;

  const fiscalTop = y;

  y = drawSectionTitle(
    page,
    "EMISOR",
    MARGIN_X,
    fiscalTop,
    columnWidth,
    boldFont,
  );

  let issuerY = y;

  issuerY = drawLabelValue(
    page,
    "Razón social",
    "MODIRA",
    MARGIN_X,
    issuerY,
    columnWidth,
    regularFont,
    boldFont,
  );

  issuerY = drawLabelValue(
    page,
    "NIF / CIF / VAT",
    "9999",
    MARGIN_X,
    issuerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  issuerY = drawLabelValue(
    page,
    "Dirección",
    "A DETERMINAR",
    MARGIN_X,
    issuerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  const issuerLocation = "A DETERMINAR";

  issuerY = drawLabelValue(
    page,
    "Localidad",
    issuerLocation,
    MARGIN_X,
    issuerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );


  const customerX =
    MARGIN_X +
    columnWidth +
    columnGap;

  let customerY = drawSectionTitle(
    page,
    "CLIENTE",
    customerX,
    fiscalTop,
    columnWidth,
    boldFont,
  );

  customerY = drawLabelValue(
    page,
    "Razón social",
    safeText(
      quotation.issuer_legal_name,
      "-",
    ),
    customerX,
    customerY,
    columnWidth,
    regularFont,
    boldFont,
  );

  customerY = drawLabelValue(
    page,
    "NIF / CIF / VAT",
    safeText(
      quotation.issuer_tax_id,
      "-",
    ),
    customerX,
    customerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  customerY = drawLabelValue(
    page,
    "Contacto",
    safeText(
      quotation.customer_contact_name,
      "-",
    ),
    customerX,
    customerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  customerY = drawLabelValue(
    page,
    "Dirección",
    safeText(
      quotation.issuer_address,
      "-",
    ),
    customerX,
    customerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  const customerLocation = [
    safeText(
      quotation.issuer_postal_code,
    ),
    safeText(
      quotation.issuer_city,
    ),
    safeText(
      quotation.issuer_province,
    ),
    safeText(
      quotation.issuer_country,
    ),
  ]
    .filter(Boolean)
    .join(", ");

  customerY = drawLabelValue(
    page,
    "Localidad",
    customerLocation || "-",
    customerX,
    customerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  y =
    Math.min(
      issuerY,
      customerY,
    ) - 12;

  // ----------------------------------------------------------
  // TÍTULO / DESCRIPCIÓN
  // ----------------------------------------------------------

  y = drawSectionTitle(
    page,
    "CONTENIDO DEL PRESUPUESTO",
    MARGIN_X,
    y,
    contentWidth,
    boldFont,
  );

  const title =
    safeText(
      quotation.titulo,
      "Sin título",
    );

  const titleLines =
    wrapText(
      title,
      boldFont,
      11,
      contentWidth,
    );

  for (const line of titleLines) {
    if (
      y <
      MARGIN_BOTTOM + 180
    ) {
      page = pdf.addPage([
        A4_WIDTH,
        A4_HEIGHT,
      ]);

      y =
        A4_HEIGHT -
        MARGIN_TOP;
    }

    page.drawText(
      normalizePdfText(line),
      {
        x: MARGIN_X,
        y,
        size: 11,
        font: boldFont,
        color: DARK,
      },
    );

    y -= 15;
  }

  y -= 4;

  const description =
    safeText(
      quotation.descripcion_detallada,
    );

  if (description) {
    const descriptionBlocks =
      description.split(/\n\s*\n/);

    for (const block of descriptionBlocks) {
      const blockLines =
        block.split(/\n/);

      for (const rawLine of blockLines) {
        const lineText =
          rawLine.trim();

        if (!lineText) {
          y -= 6;
          continue;
        }

        const wrappedLines =
          wrapText(
            lineText,
            regularFont,
            9.5,
            contentWidth,
          );

        for (const line of wrappedLines) {
          if (
            y <
            MARGIN_BOTTOM + 180
          ) {
            page = pdf.addPage([
              A4_WIDTH,
              A4_HEIGHT,
            ]);

            y =
              A4_HEIGHT -
              MARGIN_TOP;
          }

          page.drawText(
            normalizePdfText(line),
            {
              x: MARGIN_X,
              y,
              size: 9.5,
              font: regularFont,
              color: DARK,
            },
          );

          y -= 13;
        }
      }

      y -= 5;
    }
  }

  y -= 6;

  // ----------------------------------------------------------
  // SERVICIOS
  // ----------------------------------------------------------

  const services =
    parseServices(
      quotation.servicios_incluidos,
    );

  const serviceSectionHeight =
    50 +
    services.length * 30;

  if (
    y <
    MARGIN_BOTTOM +
      Math.min(
        serviceSectionHeight,
        300,
      )
  ) {
    page = pdf.addPage([
      A4_WIDTH,
      A4_HEIGHT,
    ]);

    y =
      A4_HEIGHT -
      MARGIN_TOP;
  }

  y = drawSectionTitle(
    page,
    "SERVICIOS INCLUIDOS",
    MARGIN_X,
    y,
    contentWidth,
    boldFont,
  );

  // Anchuras de columnas.
  const descriptionWidth =
    contentWidth * 0.57;

  const quantityWidth =
    contentWidth * 0.13;

  const unitPriceWidth =
    contentWidth * 0.14;

  const totalWidth =
    contentWidth * 0.16;

  const serviceX =
    MARGIN_X;

  const quantityX =
    serviceX +
    descriptionWidth;

  const unitPriceX =
    quantityX +
    quantityWidth;

  const totalX =
    unitPriceX +
    unitPriceWidth;

  const headerY = y;

  page.drawText(
    "Descripción",
    {
      x: serviceX,
      y: headerY,
      size: 8,
      font: boldFont,
      color: MUTED,
    },
  );

  // Cantidad: centrada en su columna.
  const quantityHeader = "Cant.";
  const quantityHeaderWidth =
    boldFont.widthOfTextAtSize(quantityHeader, 8);

  page.drawText(quantityHeader, {
    x: quantityX + (quantityWidth - quantityHeaderWidth) / 2,
    y: headerY,
    size: 8,
    font: boldFont,
    color: MUTED,
  });

  // Precio: alineado a la derecha.
  const priceHeader = "Precio";
  const priceHeaderWidth =
    boldFont.widthOfTextAtSize(priceHeader, 8);

  page.drawText(priceHeader, {
    x: unitPriceX + unitPriceWidth - priceHeaderWidth - 2,
    y: headerY,
    size: 8,
    font: boldFont,
    color: MUTED,
  });

  // Importe: alineado a la derecha.
  const totalHeader = "Importe";
  const totalHeaderWidth =
    boldFont.widthOfTextAtSize(totalHeader, 8);

  page.drawText(totalHeader, {
    x: totalX + totalWidth - totalHeaderWidth,
    y: headerY,
    size: 8,
    font: boldFont,
    color: MUTED,
  });
  y -= 8;

  page.drawLine({
    start: {
      x: MARGIN_X,
      y,
    },
    end: {
      x:
        MARGIN_X +
        contentWidth,
      y,
    },
    thickness: 0.7,
    color: LIGHT,
  });

  y -= 17;

  for (
    let index = 0;
    index < services.length;
    index++
  ) {
    const service =
      services[index];

    const descriptionLines =
      wrapText(
        service.descripcion,
        regularFont,
        8.5,
        descriptionWidth - 5,
      );

    const rowHeight = Math.max(
      30,
      descriptionLines.length *
        11 +
        16,
    );

    if (
      y <
      MARGIN_BOTTOM +
        220
    ) {
      page = pdf.addPage([
        A4_WIDTH,
        A4_HEIGHT,
      ]);

      y =
        A4_HEIGHT -
        MARGIN_TOP;

      y = drawSectionTitle(
        page,
        "SERVICIOS INCLUIDOS",
        MARGIN_X,
        y,
        contentWidth,
        boldFont,
      );

      page.drawText(
        "Descripción",
        {
          x: serviceX,
          y,
          size: 8,
          font: boldFont,
          color: MUTED,
        },
      );

     const quantityHeader = "Cant.";
const quantityHeaderWidth =
  boldFont.widthOfTextAtSize(quantityHeader, 8);

page.drawText(quantityHeader, {
  x: quantityX + (quantityWidth - quantityHeaderWidth) / 2,
  y,
  size: 8,
  font: boldFont,
  color: MUTED,
});

     const priceHeader = "Precio";
const priceHeaderWidth =
  boldFont.widthOfTextAtSize(priceHeader, 8);

page.drawText(priceHeader, {
  x: unitPriceX + unitPriceWidth - priceHeaderWidth - 2,
  y,
  size: 8,
  font: boldFont,
  color: MUTED,
});

   const totalHeader = "Importe";
const totalHeaderWidth =
  boldFont.widthOfTextAtSize(totalHeader, 8);

page.drawText(totalHeader, {
  x: totalX + totalWidth - totalHeaderWidth,
  y,
  size: 8,
  font: boldFont,
  color: MUTED,
});

      y -= 8;

      page.drawLine({
        start: {
          x: MARGIN_X,
          y,
        },
        end: {
          x:
            MARGIN_X +
            contentWidth,
          y,
        },
        thickness: 0.7,
        color: LIGHT,
      });

      y -= 17;
    }

    const textBlockHeight =
  descriptionLines.length * 11;

const textStartY =
  y -
  (rowHeight - textBlockHeight) / 2 -
  2;

for (
  let lineIndex = 0;
  lineIndex <
  descriptionLines.length;
  lineIndex++
) {
  page.drawText(
    normalizePdfText(
      descriptionLines[lineIndex],
    ),
    {
      x: serviceX,
      y:
        textStartY -
        lineIndex * 11,
      size: 8.5,
      font: regularFont,
      color: DARK,
    },
  );
}

    const quantityText =
      Number.isInteger(
        service.cantidad,
      )
        ? String(
            service.cantidad,
          )
        : service.cantidad
            .toLocaleString(
              "es-ES",
              {
                maximumFractionDigits: 2,
              },
            );

    const unitPriceText =
      money(service.precio);

    const lineTotal =
      service.cantidad *
      service.precio;

    const lineTotalText =
      money(lineTotal);

 const quantityTextWidth =
  regularFont.widthOfTextAtSize(
    normalizePdfText(quantityText),
    8.5,
  );

page.drawText(
  normalizePdfText(quantityText),
  {
    x: quantityX + (quantityWidth - quantityTextWidth) / 2,
    y: textStartY,
    size: 8.5,
    font: regularFont,
    color: DARK,
  },
);

    const unitPriceTextWidth =
      regularFont.widthOfTextAtSize(
        normalizePdfText(
          unitPriceText,
        ),
        8.5,
      );

    page.drawText(
      normalizePdfText(
        unitPriceText,
      ),
      {
        x:
          unitPriceX +
          unitPriceWidth -
          unitPriceTextWidth -
          2,
        y: textStartY,
        size: 8.5,
        font: regularFont,
        color: DARK,
      },
    );

    const lineTotalTextWidth =
      regularFont.widthOfTextAtSize(
        normalizePdfText(
          lineTotalText,
        ),
        8.5,
      );

    page.drawText(
      normalizePdfText(
        lineTotalText,
      ),
      {
        x:
          totalX +
          totalWidth -
          lineTotalTextWidth,
        y: textStartY,
        size: 8.5,
        font: regularFont,
        color: DARK,
      },
    );

   // Posición inferior de la fila actual.
const rowBottom = y - rowHeight;

// Dibujar la línea en la parte inferior de la fila.
const separatorY = rowBottom + 2;

page.drawLine({
  start: {
    x: MARGIN_X,
    y: separatorY,
  },
  end: {
    x: MARGIN_X + contentWidth,
    y: separatorY,
  },
  thickness: 0.35,
  color: LIGHT,
});

// Dejar espacio adicional antes del siguiente servicio.
y = rowBottom - 10;
  }

  if (services.length === 0) {
    page.drawText(
      "No hay servicios incluidos.",
      {
        x: MARGIN_X,
        y,
        size: 8.5,
        font: regularFont,
        color: MUTED,
      },
    );

    y -= 25;
  }

  // ----------------------------------------------------------
  // NOTAS
  // ----------------------------------------------------------

  const notes =
    safeText(
      quotation.notas,
    );

  if (notes) {
    if (
      y <
      MARGIN_BOTTOM + 200
    ) {
      page = pdf.addPage([
        A4_WIDTH,
        A4_HEIGHT,
      ]);

      y =
        A4_HEIGHT -
        MARGIN_TOP;
    }

    y -= 5;

    y = drawSectionTitle(
      page,
      "NOTAS",
      MARGIN_X,
      y,
      contentWidth,
      boldFont,
    );

    const noteLines =
      wrapText(
        notes,
        regularFont,
        9,
        contentWidth,
      );

    for (const line of noteLines) {
      if (
        y <
        MARGIN_BOTTOM + 180
      ) {
        page = pdf.addPage([
          A4_WIDTH,
          A4_HEIGHT,
        ]);

        y =
          A4_HEIGHT -
          MARGIN_TOP;
      }

      page.drawText(
        normalizePdfText(line),
        {
          x: MARGIN_X,
          y,
          size: 9,
          font: regularFont,
          color: DARK,
        },
      );

      y -= 12;
    }

    y -= 5;
  }

  y -= 6;
  // ----------------------------------------------------------
  // ALCANCE DEL PROYECTO ACORDADO
  // ----------------------------------------------------------

  const scopeFields = getQuotationScopeFields(quotation);

  if (scopeFields.length > 0) {
    const scopeVersionNumber =
      safeText(quotation.project_scope_version_number);

    const scopeAcceptedAt =
      dateEs(quotation.project_scope_accepted_at);

    // Reservar espacio para el título y los metadatos.
    if (y < MARGIN_BOTTOM + 100) {
      page = pdf.addPage([
        A4_WIDTH,
        A4_HEIGHT,
      ]);

      y = A4_HEIGHT - MARGIN_TOP;
    }

    y -= 6;

    y = drawSectionTitle(
      page,
      "ALCANCE DEL PROYECTO ACORDADO",
      MARGIN_X,
      y,
      contentWidth,
      boldFont,
    );

    // Información de la versión vinculada al presupuesto.
    if (scopeVersionNumber) {
      page.drawText(
        normalizePdfText(
          `Versión del alcance: V${scopeVersionNumber}`,
        ),
        {
          x: MARGIN_X,
          y,
          size: 9,
          font: boldFont,
          color: ACCENT,
        },
      );

      y -= 15;
    }

    if (scopeAcceptedAt !== "-") {
      page.drawText(
        normalizePdfText(
          `Fecha de aceptación: ${scopeAcceptedAt}`,
        ),
        {
          x: MARGIN_X,
          y,
          size: 8.5,
          font: regularFont,
          color: MUTED,
        },
      );

      y -= 18;
    }

    // Imprimir todos los campos que tengan contenido.
    for (const field of scopeFields) {
      const valueLines = field.value
        .split(/\n/)
        .map((line) => line.trim())
        .filter(Boolean);

      if (valueLines.length === 0) {
        continue;
      }

      // Evitar que el encabezado de un campo quede al final
      // de una página sin espacio para su contenido.
      if (y < MARGIN_BOTTOM + 65) {
        page = pdf.addPage([
          A4_WIDTH,
          A4_HEIGHT,
        ]);

        y = A4_HEIGHT - MARGIN_TOP;
      }

      page.drawText(
        normalizePdfText(field.label),
        {
          x: MARGIN_X,
          y,
          size: 9,
          font: boldFont,
          color: DARK,
        },
      );

      y -= 14;

      for (const valueLine of valueLines) {
        const wrappedLines = wrapText(
          valueLine,
          regularFont,
          8.5,
          contentWidth - 8,
        );

        for (const wrappedLine of wrappedLines) {
          if (y < MARGIN_BOTTOM + 35) {
            page = pdf.addPage([
              A4_WIDTH,
              A4_HEIGHT,
            ]);

            y = A4_HEIGHT - MARGIN_TOP;
          }

          page.drawText(
            normalizePdfText(wrappedLine),
            {
              x: MARGIN_X + 8,
              y,
              size: 8.5,
              font: regularFont,
              color: DARK,
            },
          );

          y -= 12;
        }
      }

      y -= 7;
    }

    // Separación antes del resumen económico.
    y -= 8;
  }

  // ----------------------------------------------------------
  // FIN DEL ALCANCE DEL PROYECTO
  // ----------------------------------------------------------
  // ----------------------------------------------------------
  // RESUMEN ECONÓMICO
  // ----------------------------------------------------------

  const summaryHeight = 154;

  if (
    y <
    MARGIN_BOTTOM +
      summaryHeight
  ) {
    page = pdf.addPage([
      A4_WIDTH,
      A4_HEIGHT,
    ]);

    y =
      A4_HEIGHT -
      MARGIN_TOP;
  }

  y = drawSectionTitle(
    page,
    "RESUMEN ECONÓMICO",
    MARGIN_X,
    y,
    contentWidth,
    boldFont,
  );

  const boxX = MARGIN_X;
  const boxWidth = contentWidth;
  const boxTop = y + 5;
  const boxBottom =
    boxTop - summaryHeight;

  page.drawRectangle({
    x: boxX,
    y: boxBottom,
    width: boxWidth,
    height: summaryHeight,
    borderColor: LIGHT,
    borderWidth: 0.8,
    color: WHITE,
  });

  const leftX = boxX + 14;
  const rightX =
    boxX +
    boxWidth -
    14;

  const drawSummaryRow = (
    label: string,
    value: string,
    rowY: number,
    labelBold = false,
  ) => {
    page.drawText(
      normalizePdfText(label),
      {
        x: leftX,
        y: rowY,
        size: labelBold ? 10 : 9,
        font: labelBold
          ? boldFont
          : regularFont,
        color: labelBold
          ? DARK
          : MUTED,
      },
    );

    const valueWidth =
      boldFont.widthOfTextAtSize(
        normalizePdfText(value),
        labelBold ? 10 : 9,
      );

    page.drawText(
      normalizePdfText(value),
      {
        x:
          rightX -
          valueWidth,
        y: rowY,
        size: labelBold ? 10 : 9,
        font: labelBold
          ? boldFont
          : regularFont,
        color: DARK,
      },
    );
  };

  let rowY =
    boxTop - 22;

  drawSummaryRow(
    "Base imponible",
    money(quotation.precio_base),
    rowY,
  );

  rowY -= 25;

  drawSummaryRow(
    `IVA (${percentage(quotation.iva_porcentaje)})`,
    money(
      Number(
        quotation.precio_total ??
          0,
      ) -
        Number(
          quotation.precio_base ??
            0,
        ) +
        Number(
          quotation.irpf_importe ??
            0,
        ),
    ),
    rowY,
  );

  rowY -= 25;

  if (
    Boolean(
      quotation.irpf_aplicado,
    )
  ) {
    drawSummaryRow(
      `IRPF (${percentage(quotation.irpf_porcentaje)})`,
      `- ${money(quotation.irpf_importe)}`,
      rowY,
    );
  } else {
    drawSummaryRow(
      "IRPF",
      "No aplicado",
      rowY,
    );
  }

  rowY -= 30;

  page.drawLine({
    start: {
      x: leftX,
      y: rowY + 11,
    },
    end: {
      x: rightX,
      y: rowY + 11,
    },
    thickness: 0.8,
    color: LIGHT,
  });

  drawSummaryRow(
    "Total presupuesto",
    money(quotation.precio_total),
    rowY,
    true,
  );

  rowY -= 29;

  drawSummaryRow(
    "IMPORTE TOTAL",
    money(quotation.precio_total),
    rowY,
    true,
  );

  // ----------------------------------------------------------
  // PIE
  // ----------------------------------------------------------

  for (const footerPage of pdf.getPages()) {
    footerPage.drawLine({
      start: {
        x: MARGIN_X,
        y: FOOTER_BOTTOM - 8,
      },
      end: {
        x:
          A4_WIDTH -
          MARGIN_X,
        y: FOOTER_BOTTOM - 8,
      },
      thickness: 0.7,
      color: LIGHT,
    });

    footerPage.drawText(
      "Documento generado automáticamente por Modira.",
      {
        x: MARGIN_X,
        y: FOOTER_BOTTOM - 24,
        size: 7.5,
        font: regularFont,
        color: MUTED,
      },
    );

    const footerNumber = normalizedVersionLabel
      ? `Presupuesto ${quotationNumber} - ${normalizedVersionLabel}`
      : `Presupuesto ${quotationNumber}`;

    const footerWidth =
      regularFont.widthOfTextAtSize(
        normalizePdfText(
          footerNumber,
        ),
        7.5,
      );

    footerPage.drawText(
      normalizePdfText(
        footerNumber,
      ),
      {
        x:
          A4_WIDTH -
          MARGIN_X -
          footerWidth,
        y: MARGIN_BOTTOM - 24,
        size: 7.5,
        font: regularFont,
        color: MUTED,
      },
    );
  }

  // ----------------------------------------------------------
  // FRANJA INFERIOR PARA LA FIRMA ELECTRÓNICA
  // ----------------------------------------------------------

  const signatureNotice =
    "Firma electrónica del cliente mediante la plataforma MODIRA";

  for (const signaturePage of pdf.getPages()) {
    const { width } = signaturePage.getSize();

    // Separación visual entre el contenido y la franja de firma.
    signaturePage.drawLine({
      start: {
        x: MARGIN_X,
        y: 188,
      },
      end: {
        x: width - MARGIN_X,
        y: 188,
      },
      thickness: 0.7,
      color: LIGHT,
    });

    const noticeWidth = regularFont.widthOfTextAtSize(
      normalizePdfText(signatureNotice),
      8.5,
    );

    // Texto alineado a la derecha.
    signaturePage.drawText(
      normalizePdfText(signatureNotice),
      {
        x: width - MARGIN_X - noticeWidth,
        y: 155,
        size: 8.5,
        font: regularFont,
        color: MUTED,
      },
    );
  }

  const pdfBytes =
    await pdf.save();

  return pdfBytes;
}

// ============================================================
// OBTENER PRESUPUESTO
// ============================================================

async function getQuotation(
  quotationId: string,
) {
  const {
    data,
    error,
  } = await supabaseAdmin
    .from("quotations")
    .select(
      [
        "id",
        "company_id",
        "user_id",
        "project_id",
        "client_id",
        "numero_presupuesto",
        "titulo",
        "descripcion_detallada",
        "servicios_incluidos",
        "precio_base",
        "iva_porcentaje",
        "precio_total",
        "estado",
        "fecha_emision",
        "fecha_validez",
        "notas",
        "irpf_aplicado",
        "irpf_porcentaje",
        "irpf_importe",
        "document_path",
        "document_sha256",
        "quotation_version",
        "issuer_legal_name",
        "issuer_tax_id",
        "issuer_address",
        "issuer_postal_code",
        "issuer_city",
        "issuer_province",
        "issuer_country",
        "customer_legal_name",
        "customer_tax_id",
        "customer_address",
        "customer_postal_code",
        "customer_city",
        "customer_province",
               "customer_country",
        "customer_contact_name",

        // Snapshot del alcance aceptado asociado al presupuesto.
        "project_scope_version_id",
        "project_scope_acceptance_id",
        "project_scope_version_number",
        "project_scope_accepted_at",
        "project_scope_snapshot",
        "project_scope_snapshot_sha256",
        "project_scope_pdf_sha256",
      ].join(", "),
    )
    .eq("id", quotationId)
    .maybeSingle();

  if (error) {
    throw new Error(
      `No se ha podido obtener el presupuesto: ${error.message}`,
    );
  }

  if (!data) {
    throw new Error(
      "El presupuesto no existe",
    );
  }

  return data as Record<string, any>;
}

// ============================================================
// FINALIZAR DOCUMENTO BACKEND
// ============================================================

async function finalizeBackendDocument(
  quotationId: string,
  documentPath: string,
  documentSha256: string,
) {
  const {
    data,
    error,
  } = await supabaseAdmin.rpc(
    "finalize_quotation_backend_document",
    {
      p_quotation_id:
        quotationId,
      p_document_path:
        documentPath,
      p_document_sha256:
        documentSha256,
    },
  );

  if (error) {
    throw new Error(
      `No se ha podido finalizar el documento del presupuesto: ${error.message}`,
    );
  }

  return data;
}

// ============================================================
// GENERAR + SUBIR + HASH + FINALIZAR
// ============================================================

async function generateAndFinalizeQuotationDocument(
  quotation: Record<string, any>,
) {
  const quotationId =
    String(quotation.id);

  const quotationNumber =
    safeText(
      quotation.numero_presupuesto,
    );

  if (!quotationNumber) {
    throw new Error(
      "El presupuesto no tiene número de presupuesto",
    );
  }

  if (!quotation.company_id) {
    throw new Error(
      "El presupuesto no tiene company_id",
    );
  }

  // Si ya está finalizado exactamente, no hacemos nada.
  if (
    quotation.document_path &&
    quotation.document_sha256
  ) {
    return {
      quotation,
      document_path:
        quotation.document_path,
      document_sha256:
        quotation.document_sha256,
      already_finalized: true,
      reused_existing_object: false,
    };
  }

  // El flujo normal de generación se realiza sobre presupuestos
  // pendientes. La aceptación posterior queda protegida por SQL.
  if (
    safeText(
      quotation.estado,
    ).toLowerCase() !==
    "pendiente"
  ) {
    throw new Error(
      "Solo se puede generar automáticamente el PDF de un presupuesto pendiente",
    );
  }

  // Si existe acknowledgement no se debe sustituir/regenerar.
  const {
    data: acknowledgement,
    error:
      acknowledgementError,
  } = await supabaseAdmin
    .from(
      "quotation_document_acknowledgements",
    )
    .select("id")
    .eq(
      "quotation_id",
      quotationId,
    )
    .limit(1)
    .maybeSingle();

  if (acknowledgementError) {
    throw new Error(
      `No se ha podido comprobar el acknowledgement del presupuesto: ${acknowledgementError.message}`,
    );
  }

  if (acknowledgement) {
    throw new Error(
      "El documento del presupuesto ya tiene un acknowledgement y no puede regenerarse",
    );
  }

  const pdfBytes =
    await generateQuotationPdf(
      quotation,
    );

  if (pdfBytes.byteLength <= 0) {
    throw new Error(
      "El PDF generado está vacío",
    );
  }

  if (
    pdfBytes.byteLength >
    MAX_FILE_SIZE
  ) {
    throw new Error(
      "El PDF generado supera el tamaño máximo permitido",
    );
  }

  const documentPath =
    `${quotation.company_id}/${quotationNumber}.pdf`;

  // ----------------------------------------------------------
  // SUBIR PDF
  // ----------------------------------------------------------

  const {
    error: uploadError,
  } = await supabaseAdmin.storage
    .from(BUCKET_NAME)
    .upload(
      documentPath,
      pdfBytes,
      {
        contentType:
          "application/pdf",
        cacheControl:
          "3600",
        upsert: false,
      },
    );

  if (uploadError) {
    // Si ya existe exactamente ese objeto, reutilizamos solo si
    // su contenido es idéntico al PDF que acabamos de generar.
    if (
      /already exists|duplicate|exists/i.test(
        uploadError.message,
      )
    ) {
      const {
        data: existingFile,
        error: downloadError,
      } =
        await supabaseAdmin.storage
          .from(BUCKET_NAME)
          .download(
            documentPath,
          );

      if (
        downloadError ||
        !existingFile
      ) {
        throw new Error(
          `El PDF ya existe pero no se ha podido recuperar: ${downloadError?.message ?? "documento no disponible"}`,
        );
      }

      const existingBuffer =
        await existingFile.arrayBuffer();

      if (
        existingBuffer.byteLength <=
        0
      ) {
        throw new Error(
          "El PDF existente está vacío",
        );
      }

      if (
        existingBuffer.byteLength >
        MAX_FILE_SIZE
      ) {
        throw new Error(
          "El PDF existente supera el tamaño máximo permitido",
        );
      }

      const existingHash =
        await calculateSha256(
          existingBuffer,
        );

      const newHash =
        await calculateSha256(
          toArrayBuffer(
            pdfBytes,
          ),
        );

      if (
        existingHash !==
        newHash
      ) {
        throw new Error(
          "Ya existe un PDF con el mismo número de presupuesto pero su contenido no coincide con el documento generado. No se ha sustituido el documento.",
        );
      }

      const finalized =
        await finalizeBackendDocument(
          quotationId,
          documentPath,
          existingHash,
        );

      return {
        quotation: finalized,
        document_path:
          documentPath,
        document_sha256:
          existingHash,
        already_finalized: false,
        reused_existing_object:
          true,
      };
    }

    throw new Error(
      `No se ha podido guardar el PDF en Storage: ${uploadError.message}`,
    );
  }

  // ----------------------------------------------------------
  // HASH DEL PDF REAL GENERADO
  // ----------------------------------------------------------

  const pdfBuffer =
    toArrayBuffer(
      pdfBytes,
    );

  const documentSha256 =
    await calculateSha256(
      pdfBuffer,
    );

  if (
    !/^[0-9a-f]{64}$/.test(
      documentSha256,
    )
  ) {
    throw new Error(
      "El SHA-256 calculado no tiene un formato válido",
    );
  }

  // ----------------------------------------------------------
  // FINALIZACIÓN BACKEND
  // ----------------------------------------------------------

  const finalized =
    await finalizeBackendDocument(
      quotationId,
      documentPath,
      documentSha256,
    );

  return {
    quotation: finalized,
    document_path:
      documentPath,
    document_sha256:
      documentSha256,
    already_finalized: false,
    reused_existing_object:
      false,
  };
}

// ============================================================
// OBTENER VERSIÓN OFICIAL
// ============================================================

async function getOfficialVersion(versionId: string) {
  const { data, error } = await supabaseAdmin
    .from("quotation_official_versions")
    .select([
      "id",
      "quotation_id",
      "version_major",
      "version_minor",
      "version_label",
      "content_snapshot",
      "document_path",
      "document_sha256",
      "is_current",
      "published_by",
      "published_at",
      "client_notified_at",
    ].join(", "))
    .eq("id", versionId)
    .maybeSingle();

  if (error) {
    throw new Error(
      `No se ha podido obtener la versión oficial: ${error.message}`,
    );
  }

  if (!data) {
    throw new Error("La versión oficial no existe");
  }

  return data as Record<string, any>;
}

// ============================================================
// GENERAR PDF INMUTABLE DE UNA VERSIÓN OFICIAL
// ============================================================

async function generateAndFinalizeOfficialVersionDocument(
  versionId: string,
  authenticatedClient: SupabaseClient,
) {
  if (!versionId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(versionId)) {
    throw new Error("version_id no es un UUID válido");
  }

  const version = await getOfficialVersion(versionId);

  if (version.is_current !== true) {
    throw new Error(
      "Solo se puede generar el PDF de la versión oficial actual",
    );
  }

  const quotation = await getQuotation(String(version.quotation_id));

  if (
    safeText(quotation.estado).toLowerCase() !== "pendiente"
  ) {
    throw new Error(
      "Solo se puede generar el PDF de un presupuesto pendiente de respuesta",
    );
  }

  const versionLabel = safeText(version.version_label);
  if (!/^V[1-9][0-9]*(\.[1-9][0-9]*)?$/.test(versionLabel)) {
    throw new Error("La etiqueta de la versión oficial no es válida");
  }

  const expectedPath =
    `${quotation.company_id}/${quotation.numero_presupuesto}/${versionLabel}.pdf`;

  if (
    version.document_path &&
    version.document_sha256
  ) {
    if (version.document_path !== expectedPath) {
      throw new Error(
        "La ruta del documento ya registrado no coincide con la versión oficial",
      );
    }

    if (!/^[0-9a-f]{64}$/i.test(String(version.document_sha256))) {
      throw new Error("El SHA-256 registrado para la versión no es válido");
    }

    return {
      quotation_id: quotation.id,
      version_id: version.id,
      version_label: versionLabel,
      document_path: version.document_path,
      document_sha256: String(version.document_sha256).toLowerCase(),
      already_finalized: true,
      reused_existing_object: false,
      official_version: version,
    };
  }

  if (version.document_path || version.document_sha256) {
    throw new Error(
      "La versión tiene datos documentales incompletos; no se sustituirá automáticamente",
    );
  }

  if (!quotation.company_id || !quotation.numero_presupuesto) {
    throw new Error(
      "El presupuesto no tiene empresa o número de presupuesto válido",
    );
  }

  const snapshot =
    version.content_snapshot &&
    typeof version.content_snapshot === "object" &&
    !Array.isArray(version.content_snapshot)
      ? version.content_snapshot as Record<string, any>
      : null;

  if (!snapshot) {
    throw new Error(
      "La versión oficial no contiene una instantánea válida del presupuesto",
    );
  }

  // El PDF se genera a partir de la instantánea inmutable publicada,
  // no de los campos editables actuales de quotations.
  const snapshotQuotation = {
    ...snapshot,
    id: quotation.id,
    company_id: quotation.company_id,
    project_id: quotation.project_id,
    user_id: quotation.user_id,
    client_id: quotation.client_id,
    numero_presupuesto: quotation.numero_presupuesto,
  };

  const pdfBytes = await generateQuotationPdf(
    snapshotQuotation,
    versionLabel,
  );

  if (pdfBytes.byteLength <= 0) {
    throw new Error("El PDF generado está vacío");
  }

  // La migración limita este documento a 10 MiB en el RPC de registro.
  const maxVersionPdfSize = 10 * 1024 * 1024;
  if (pdfBytes.byteLength > maxVersionPdfSize) {
    throw new Error("El PDF de la versión supera el tamaño máximo de 10 MiB");
  }

  const newHash = await calculateSha256(toArrayBuffer(pdfBytes));
  if (!/^[0-9a-f]{64}$/.test(newHash)) {
    throw new Error("El SHA-256 calculado no tiene un formato válido");
  }

  let reusedExistingObject = false;
  let uploadedByThisRequest = false;
  let finalHash = newHash;

  // La ruta oficial contiene subdirectorios:
  // <company_id>/<numero_presupuesto>/<version_label>.pdf
  // Las políticas RLS históricas de Storage solo admiten la ruta legacy
  // <company_id>/<numero_presupuesto>.pdf. La subida se realiza con
  // service_role desde el backend, después de validar al trabajador y la
  // versión en esta Edge Function. El registro de la versión sigue pasando
  // por set_quotation_official_version_document con la sesión autenticada.
  const { error: uploadError } = await supabaseAdmin.storage
    .from(BUCKET_NAME)
    .upload(expectedPath, pdfBytes, {
      contentType: "application/pdf",
      cacheControl: "3600",
      upsert: false,
    });

  if (uploadError) {
    if (!/already exists|duplicate|exists/i.test(uploadError.message)) {
      throw new Error(
        `No se ha podido subir el PDF de la versión oficial: ${uploadError.message}`,
      );
    }

    // No sobrescribir nunca un objeto preexistente: solo reutilizarlo si
    // sus bytes son idénticos al PDF que acabamos de generar.
    const { data: existingFile, error: downloadError } =
      await supabaseAdmin.storage
        .from(BUCKET_NAME)
        .download(expectedPath);

    if (downloadError || !existingFile) {
      throw new Error(
        `El PDF ya existe pero no se ha podido verificar: ${downloadError?.message ?? "documento no disponible"}`,
      );
    }

    const existingBuffer = await existingFile.arrayBuffer();
    if (
      existingBuffer.byteLength <= 0 ||
      existingBuffer.byteLength > maxVersionPdfSize
    ) {
      throw new Error("El PDF existente está vacío o supera 10 MiB");
    }

    const existingHash = await calculateSha256(existingBuffer);
    if (existingHash !== newHash) {
      throw new Error(
        "Ya existe un PDF en la ruta de esta versión con contenido diferente. No se ha sobrescrito.",
      );
    }

    reusedExistingObject = true;
    finalHash = existingHash;
  } else {
    uploadedByThisRequest = true;
  }

  const { data: registeredVersion, error: registerError } =
    await authenticatedClient.rpc(
      "set_quotation_official_version_document",
      {
        p_version_id: version.id,
        p_document_path: expectedPath,
        p_document_sha256: finalHash,
      },
    );

  if (registerError) {
    // Si esta petición creó el objeto y el registro SQL falla, intentamos
    // retirar únicamente ese objeto recién creado. Nunca borramos un objeto
    // que ya existía antes de la petición.
    if (uploadedByThisRequest) {
      const { error: cleanupError } = await supabaseAdmin.storage
        .from(BUCKET_NAME)
        .remove([expectedPath]);

      if (cleanupError) {
        console.error(
          "No se pudo limpiar el PDF subido tras fallar el registro:",
          cleanupError,
        );
      }
    }

    throw new Error(
      `No se ha podido registrar el PDF de la versión oficial: ${registerError.message}`,
    );
  }

  return {
    quotation_id: quotation.id,
    version_id: version.id,
    version_label: versionLabel,
    document_path: expectedPath,
    document_sha256: finalHash,
    already_finalized: false,
    reused_existing_object: reusedExistingObject,
    official_version: registeredVersion,
  };
}

// ============================================================
// HASH LEGACY DE PDF YA EXISTENTE
// ============================================================
//
// Se mantiene el flujo anterior para presupuestos que ya tengan
// un PDF subido manualmente y que solo necesiten calcular/registrar
// su SHA-256.
//
// Las nuevas generaciones utilizan el flujo backend anterior.
// ============================================================

async function hashExistingQuotationDocument(
  quotation: Record<string, any>,
  authenticatedClient: SupabaseClient,
) {
  const quotationId =
    String(quotation.id);

  const documentPath =
    String(
      quotation.document_path ?? "",
    ).trim();

  if (!documentPath) {
    throw new Error(
      "El presupuesto no tiene un documento asociado",
    );
  }

  const expectedDocumentPath =
    `${quotation.company_id}/${quotation.numero_presupuesto}.pdf`;

  if (
    documentPath !==
    expectedDocumentPath
  ) {
    throw new Error(
      "La ruta del documento del presupuesto no coincide con la ruta esperada",
    );
  }

  const {
    data: file,
    error: downloadError,
  } =
    await supabaseAdmin.storage
      .from(BUCKET_NAME)
      .download(
        documentPath,
      );

  if (downloadError) {
    throw new Error(
      `No se ha podido obtener el PDF asociado al presupuesto: ${downloadError.message}`,
    );
  }

  if (!file) {
    throw new Error(
      "El PDF asociado no existe en Storage",
    );
  }

  if (
    file.size <= 0
  ) {
    throw new Error(
      "El documento PDF está vacío",
    );
  }

  if (
    file.size >
    10 * 1024 * 1024
  ) {
    throw new Error(
      "El documento PDF supera el tamaño máximo permitido",
    );
  }

  const firstBytes =
    new Uint8Array(
      await file
        .slice(0, 5)
        .arrayBuffer(),
    );

  const pdfMagic =
    new TextDecoder().decode(
      firstBytes,
    );

  if (
    pdfMagic !==
    "%PDF-"
  ) {
    throw new Error(
      "El archivo asociado al presupuesto no es un PDF válido",
    );
  }

  const fileBuffer =
    await file.arrayBuffer();

  const documentSha256 =
    await calculateSha256(
      fileBuffer,
    );

  if (
    !/^[0-9a-f]{64}$/.test(
      documentSha256,
    )
  ) {
    throw new Error(
      "El SHA-256 calculado no tiene un formato válido",
    );
  }

  const {
    data: updatedQuotation,
    error: hashError,
  } =
    await authenticatedClient.rpc(
      "set_quotation_document_hash",
      {
        p_quotation_id:
          quotationId,
        p_document_path:
          documentPath,
        p_document_sha256:
          documentSha256,
      },
    );

  if (hashError) {
    throw new Error(
      `No se ha podido registrar la huella digital del documento: ${hashError.message}`,
    );
  }

  return {
    quotation:
      updatedQuotation,
    document_path:
      documentPath,
    document_sha256:
      documentSha256,
  };
}
// ============================================================
// ACEPTACIÓN CONTRACTUAL CON FIRMA DEL CLIENTE
// ============================================================

async function signAndAcceptQuotation(
  bodyRecord: Record<string, unknown>,
  authenticatedClient: SupabaseClient,
  userAgent: string | null,
) {
  const quotationId =
    typeof bodyRecord.quotation_id === "string"
      ? bodyRecord.quotation_id.trim()
      : "";

  const versionId =
    typeof bodyRecord.official_version_id === "string"
      ? bodyRecord.official_version_id.trim()
      : "";

  const signatureBase64 =
    typeof bodyRecord.signature_png_base64 === "string"
      ? bodyRecord.signature_png_base64
      : "";

  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  if (!uuidPattern.test(quotationId)) {
    throw new Error("quotation_id no es un UUID válido");
  }

  if (!uuidPattern.test(versionId)) {
    throw new Error("official_version_id no es un UUID válido");
  }

  if (
    !signatureBase64 ||
    signatureBase64.length > 2 * 1024 * 1024
  ) {
    throw new Error("La firma está vacía o supera el tamaño permitido");
  }

  // Aceptar únicamente una imagen PNG en Base64.
  const normalizedBase64 = signatureBase64.replace(
    /^data:image\/png;base64,/i,
    "",
  );

  if (
    !/^[A-Za-z0-9+/]+={0,2}$/.test(normalizedBase64) ||
    normalizedBase64.length % 4 !== 0
  ) {
    throw new Error("La firma debe ser una imagen PNG en Base64");
  }

  let binarySignature: string;

  try {
    binarySignature = atob(normalizedBase64);
  } catch {
    throw new Error("No se ha podido decodificar la imagen de la firma");
  }

  const signatureBytes = Uint8Array.from(
    binarySignature,
    (character) => character.charCodeAt(0),
  );

  // Validar la cabecera PNG.
  const pngHeader = [137, 80, 78, 71, 13, 10, 26, 10];

  if (
    signatureBytes.length < 8 ||
    !pngHeader.every(
      (byte, index) => signatureBytes[index] === byte,
    )
  ) {
    throw new Error("La imagen de la firma no es un PNG válido");
  }

  // Obtener el presupuesto.
  const quotation = await getQuotation(quotationId);

  if (
    safeText(quotation.estado).toLowerCase() !== "pendiente"
  ) {
    throw new Error("El presupuesto ya no está pendiente");
  }

  if (!quotation.company_id || !quotation.numero_presupuesto) {
    throw new Error("El presupuesto no tiene empresa o número válido");
  }

  // Obtener la versión oficial vigente.
  const version = await getOfficialVersion(versionId);

  if (
    version.quotation_id !== quotationId ||
    version.is_current !== true
  ) {
    throw new Error("La versión oficial no corresponde al presupuesto");
  }

  if (
    !version.document_path ||
    !version.document_sha256 ||
    quotation.document_path !== version.document_path ||
    String(quotation.document_sha256 ?? "").toLowerCase() !==
      String(version.document_sha256).toLowerCase()
  ) {
    throw new Error(
      "El PDF original no coincide con la versión oficial vigente",
    );
  }

  // Descargar el PDF original sin modificarlo.
  const {
    data: originalFile,
    error: downloadError,
  } = await supabaseAdmin.storage
    .from(BUCKET_NAME)
    .download(version.document_path);

  if (downloadError || !originalFile) {
    throw new Error(
      `No se ha podido descargar el PDF original: ${
        downloadError?.message ?? "archivo no disponible"
      }`,
    );
  }

  const originalBytes = new Uint8Array(
    await originalFile.arrayBuffer(),
  );

  const originalHash = await calculateSha256(
    toArrayBuffer(originalBytes),
  );

  if (
    originalHash.toLowerCase() !==
    String(version.document_sha256).toLowerCase()
  ) {
    throw new Error(
      "El contenido del PDF original no coincide con su SHA-256 registrado",
    );
  }

  // ----------------------------------------------------------
  // IDENTIFICAR AL USUARIO AUTENTICADO QUE FIRMA
  // ----------------------------------------------------------

  const {
    data: { user },
    error: userError,
  } = await authenticatedClient.auth.getUser();

  if (userError || !user) {
    throw new Error(
      "No se ha podido identificar al usuario autenticado que firma",
    );
  }

  const {
    data: signerProfile,
    error: signerProfileError,
  } = await supabaseAdmin
    .from("profiles")
    .select("nombre")
    .eq("id", user.id)
    .eq("status", "active")
    .maybeSingle();

  if (
    signerProfileError ||
    !signerProfile ||
    !safeText(signerProfile.nombre)
  ) {
    throw new Error(
      "No se ha podido obtener el nombre del usuario firmante desde su perfil activo",
    );
  }

  const signerName = safeText(signerProfile.nombre);

  // ----------------------------------------------------------
  // GENERAR EL PDF FIRMADO
  // ----------------------------------------------------------

  const signedBytes = await generateSignedQuotationPdf(
    originalBytes,
    signatureBytes,
    signerName,
  );

  const signedHash = await calculateSha256(
    toArrayBuffer(signedBytes),
  );

  const signatureHash = await calculateSha256(
    toArrayBuffer(signatureBytes),
  );

  // Mantener el original y guardar el PDF firmado por separado.
  const signedPath =
    `${quotation.company_id}/${quotation.numero_presupuesto}_signed.pdf`;

  // No sobrescribir un documento firmado preexistente.
  const {
    error: uploadError,
  } = await supabaseAdmin.storage
    .from(BUCKET_NAME)
    .upload(signedPath, signedBytes, {
      contentType: "application/pdf",
      cacheControl: "3600",
      upsert: false,
    });

  if (uploadError) {
    throw new Error(
      `No se ha podido guardar el PDF firmado: ${uploadError.message}`,
    );
  }

  // Registrar la firma y completar la aceptación contractual.
  // Se usa el cliente autenticado para que auth.uid() esté disponible
  // dentro de la función SQL.
  const {
    data: acceptedQuotation,
    error: acceptanceError,
  } = await authenticatedClient.rpc(
    "finalize_quotation_signed_acceptance",
    {
      p_quotation_id: quotationId,
      p_official_version_id: versionId,
      p_source_document_path: version.document_path,
      p_source_document_sha256: originalHash,
      p_signed_document_path: signedPath,
      p_signed_document_sha256: signedHash,
      p_signature_image_sha256: signatureHash,
      p_user_agent: userAgent,
    },
  );

  if (acceptanceError) {
    // El PDF original nunca se elimina.
    // Si la aceptación falla, retirar únicamente el PDF firmado
    // que acaba de crear esta petición.
    const { error: cleanupError } = await supabaseAdmin.storage
      .from(BUCKET_NAME)
      .remove([signedPath]);

    if (cleanupError) {
      console.error(
        "No se pudo limpiar el PDF firmado tras fallar la aceptación:",
        cleanupError,
      );
    }

    throw new Error(
      `No se ha podido completar la aceptación: ${acceptanceError.message}`,
    );
  }

  return {
    quotation: acceptedQuotation,
    quotation_id: quotationId,
    official_version_id: versionId,
    original_document_path: version.document_path,
    signed_document_path: signedPath,
    signed_document_sha256: signedHash,
  };
}
// ============================================================
// RESPUESTAS
// ============================================================

function jsonResponse(
  body: unknown,
  status: number,
  corsHeaders: Record<string, string>,
): Response {
  return new Response(
    JSON.stringify(body),
    {
      status,
      headers: {
        ...corsHeaders,
        "Content-Type":
          "application/json; charset=utf-8",
      },
    },
  );
}

// ============================================================
// EDGE FUNCTION
// ============================================================

Deno.serve(
  async (req) => {
    const corsHeaders =
      getCorsHeaders(
        req.headers.get("Origin"),
      );

    // ----------------------------------------------------------
    // OPTIONS
    // ----------------------------------------------------------

    if (
      req.method ===
      "OPTIONS"
    ) {
      return new Response(
        "ok",
        {
          headers:
            corsHeaders,
        },
      );
    }

    // ----------------------------------------------------------
    // MÉTODO
    // ----------------------------------------------------------

    if (
      req.method !==
      "POST"
    ) {
      return jsonResponse(
        {
          error:
            "Método no permitido",
        },
        405,
        corsHeaders,
      );
    }

    try {
      // --------------------------------------------------------
      // 1. AUTORIZACIÓN
      // --------------------------------------------------------

      const authHeader =
        req.headers.get(
          "Authorization",
        );

      if (!authHeader) {
        return jsonResponse(
          {
            error:
              "No autenticado",
          },
          401,
          corsHeaders,
        );
      }

      // --------------------------------------------------------
      // 2. CLIENTE CON SESIÓN DEL WORKER
      // --------------------------------------------------------

      const supabase =
        createClient(
          supabaseUrl,
          supabaseAnonKey,
          {
            global: {
              headers: {
                Authorization:
                  authHeader,
              },
            },
            auth: {
              autoRefreshToken:
                false,
              persistSession:
                false,
              detectSessionInUrl:
                false,
            },
          },
        );

      // --------------------------------------------------------
      // 3. USUARIO ACTUAL
      // --------------------------------------------------------

      const {
        data: {
          user,
        },
        error: userError,
      } =
        await supabase.auth.getUser();

      if (
        userError ||
        !user
      ) {
        console.error(
          "Error verificando usuario:",
          userError,
        );

        return jsonResponse(
          {
            error:
              "Sesión no válida",
          },
          401,
          corsHeaders,
        );
      }

      // --------------------------------------------------------
      // 5. BODY
      // --------------------------------------------------------

      let body: unknown;

      try {
        body =
          await req.json();
      } catch {
        return jsonResponse(
          {
            error:
              "El cuerpo de la petición no es JSON válido",
          },
          400,
          corsHeaders,
        );
      }

      const bodyRecord =
        (
          body as Record<
            string,
            unknown
          >
        ) ?? {};

      const requestedAction =
        typeof bodyRecord.action === "string"
          ? String(bodyRecord.action).trim()
          : "";
const quotationId =
  typeof bodyRecord.quotation_id === "string"
    ? bodyRecord.quotation_id.trim()
    : "";
    // --------------------------------------------------------
// COMPROBAR SI EL USUARIO ES TRABAJADOR
// --------------------------------------------------------

const {
  data: isWorker,
  error: workerError,
} = await supabase.rpc("current_user_is_worker");

if (workerError) {
  console.error(
    "Error comprobando trabajador:",
    workerError,
  );

  return jsonResponse(
    {
      error: "No se ha podido verificar el permiso de trabajador",
    },
    500,
    corsHeaders,
  );
}

if (
  isWorker !== true &&
  requestedAction !== "sign_and_accept_quotation"
) {
  return jsonResponse(
    {
      error: "Acceso denegado: se requiere un trabajador activo",
    },
    403,
    corsHeaders,
  );
}

// --------------------------------------------------------
// ACEPTACIÓN CON FIRMA DEL CLIENTE
// --------------------------------------------------------

if (requestedAction === "sign_and_accept_quotation") {
  if (isWorker === true) {
    return jsonResponse(
      {
        error: "Esta acción está reservada a la aceptación del cliente",
      },
      403,
      corsHeaders,
    );
  }

  const result = await signAndAcceptQuotation(
    bodyRecord,
    supabase,
    req.headers.get("User-Agent"),
  );

  return jsonResponse(
    {
      success: true,
      mode: "signed_quotation_acceptance",
      ...result,
    },
    200,
    corsHeaders,
  );
}
// --------------------------------------------------------
// COMPROBAR PERMISOS DEL TRABAJADOR
// --------------------------------------------------------

if (isWorker === true) {
  const isOfficialVersionAction =
    requestedAction === "generate_quotation_official_version_document" ||
    requestedAction === "generate_quotation_version_document";

  const permissionCodes = isOfficialVersionAction
    ? ["quotations.update", "quotations.create"]
    : ["quotations.update"];

  const permissionResults = await Promise.all(
    permissionCodes.map((permissionCode) =>
      supabase.rpc(
        "current_worker_has_permission",
        { p_permission_code: permissionCode },
      )
    ),
  );

  const permissionError = permissionResults.find(
    (result) => result.error,
  );

  if (permissionError?.error) {
    console.error(
      "Error comprobando permisos de presupuestos:",
      permissionError.error,
    );

    return jsonResponse(
      {
        error: "No se han podido verificar los permisos del trabajador",
      },
      500,
      corsHeaders,
    );
  }

  if (!permissionResults.some((result) => result.data === true)) {
    return jsonResponse(
      {
        error: isOfficialVersionAction
          ? "Acceso denegado: se requiere quotations.create o quotations.update"
          : "Acceso denegado: se requiere el permiso quotations.update",
      },
      403,
      corsHeaders,
    );
  }
}
      // --------------------------------------------------------
// GENERAR PDF DE UNA VERSIÓN OFICIAL
// --------------------------------------------------------

if (
  requestedAction === "generate_quotation_official_version_document" ||
  requestedAction === "generate_quotation_version_document"
) {
  const versionId =
    typeof bodyRecord.version_id === "string"
      ? bodyRecord.version_id.trim()
      : typeof bodyRecord.official_version_id === "string"
        ? bodyRecord.official_version_id.trim()
        : "";

  if (!versionId) {
    return jsonResponse(
      {
        error: "Falta el identificador de la versión oficial",
      },
      400,
      corsHeaders,
    );
  }

  const result = await generateAndFinalizeOfficialVersionDocument(
    versionId,
    supabase,
  );

  return jsonResponse(
    {
      success: true,
      mode: "official_version_pdf",
      ...result,
    },
    200,
    corsHeaders,
  );
}
      // --------------------------------------------------------
      // 6. OBTENER PRESUPUESTO
      // --------------------------------------------------------
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

if (!uuidPattern.test(quotationId)) {
  return jsonResponse(
    {
      error: "quotation_id no es un UUID válido",
    },
    400,
    corsHeaders,
  );
}
      const quotation =
        await getQuotation(
          quotationId,
        );

      // --------------------------------------------------------
      // 7. GENERACIÓN AUTOMÁTICA
      // --------------------------------------------------------
      //
      // Acción explícita:
      //   generate_quotation_document
      //
      // Comportamiento por defecto:
      //   si no hay document_path, genera el PDF.
      //
      // --------------------------------------------------------

      if (
        requestedAction ===
          "generate_quotation_document" ||
        (
          !requestedAction &&
          !quotation.document_path
        )
      ) {
        const result =
          await generateAndFinalizeQuotationDocument(
            quotation,
          );

        return jsonResponse(
          {
            success: true,
            mode:
              "automatic_pdf",
            quotation_id:
              quotationId,
            document_path:
              result.document_path,
            document_sha256:
              result.document_sha256,
            already_finalized:
              result.already_finalized ??
              false,
            reused_existing_object:
              result.reused_existing_object ??
              false,
            quotation:
              result.quotation,
          },
          200,
          corsHeaders,
        );
      }

      // --------------------------------------------------------
      // 8. COMPATIBILIDAD — HASH DE PDF EXISTENTE
      // --------------------------------------------------------

      if (
        requestedAction ===
          "set_quotation_document_hash" ||
        quotation.document_path
      ) {
        const result =
          await hashExistingQuotationDocument(
            quotation,
            supabase,
          );

        return jsonResponse(
          {
            success: true,
            mode:
              "existing_document_hash",
            quotation_id:
              quotationId,
            document_path:
              result.document_path,
            document_sha256:
              result.document_sha256,
            quotation:
              result.quotation,
          },
          200,
          corsHeaders,
        );
      }

      // --------------------------------------------------------
      // 9. ESTADO IMPOSIBLE
      // --------------------------------------------------------

      return jsonResponse(
        {
          error:
            "No se ha podido determinar la operación documental del presupuesto",
        },
        409,
        corsHeaders,
      );
    } catch (error) {
      console.error(
        "quotation-document error:",
        error,
      );

      const message =
        error instanceof Error
          ? error.message
          : "Error interno al procesar el documento del presupuesto";

      return jsonResponse(
        {
          error: message,
        },
        500,
        corsHeaders,
      );
    }
  },
);
