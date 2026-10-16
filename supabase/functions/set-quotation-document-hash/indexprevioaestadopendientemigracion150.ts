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
const MARGIN_BOTTOM = 48;

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
// PDF — GENERACIÓN OFICIAL DEL PRESUPUESTO
// ============================================================

async function generateQuotationPdf(
  quotation: Record<string, any>,
): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();

  const quotationNumber =
    normalizePdfText(
      safeText(
        quotation.numero_presupuesto,
        "-",
      ),
    );

  pdf.setTitle(
    `Presupuesto ${quotationNumber}`,
  );

  pdf.setAuthor("Modira");
  pdf.setSubject(
    "Presupuesto emitido por Modira",
  );
  pdf.setCreator("Modira");
  pdf.setProducer("Modira");

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

  page.drawText(
    "Cant.",
    {
      x: quantityX,
      y: headerY,
      size: 8,
      font: boldFont,
      color: MUTED,
    },
  );

  page.drawText(
    "Precio",
    {
      x: unitPriceX,
      y: headerY,
      size: 8,
      font: boldFont,
      color: MUTED,
    },
  );

  page.drawText(
    "Importe",
    {
      x: totalX,
      y: headerY,
      size: 8,
      font: boldFont,
      color: MUTED,
    },
  );

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

      page.drawText(
        "Cant.",
        {
          x: quantityX,
          y,
          size: 8,
          font: boldFont,
          color: MUTED,
        },
      );

      page.drawText(
        "Precio",
        {
          x: unitPriceX,
          y,
          size: 8,
          font: boldFont,
          color: MUTED,
        },
      );

      page.drawText(
        "Importe",
        {
          x: totalX,
          y,
          size: 8,
          font: boldFont,
          color: MUTED,
        },
      );

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

    page.drawText(
      normalizePdfText(
        quantityText,
      ),
      {
        x: quantityX,
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

    y -= 8;
  }

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
        y: MARGIN_BOTTOM - 8,
      },
      end: {
        x:
          A4_WIDTH -
          MARGIN_X,
        y: MARGIN_BOTTOM - 8,
      },
      thickness: 0.7,
      color: LIGHT,
    });

    footerPage.drawText(
      "Documento generado automáticamente por Modira.",
      {
        x: MARGIN_X,
        y: MARGIN_BOTTOM - 24,
        size: 7.5,
        font: regularFont,
        color: MUTED,
      },
    );

    const footerNumber =
      `Presupuesto ${quotationNumber}`;

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
      // 4. COMPROBAR WORKER
      // --------------------------------------------------------

      const {
        data: isWorker,
        error:
          workerError,
      } =
        await supabase.rpc(
          "current_user_is_worker",
        );

      if (workerError) {
        console.error(
          "Error comprobando trabajador:",
          workerError,
        );

        return jsonResponse(
          {
            error:
              "No se ha podido verificar el permiso de trabajador",
          },
          500,
          corsHeaders,
        );
      }

      if (
        isWorker !==
        true
      ) {
        return jsonResponse(
          {
            error:
              "Acceso denegado: se requiere un trabajador activo",
          },
          403,
          corsHeaders,
        );
      }

      // --------------------------------------------------------
      // 4B. PERMISO RBAC
      // --------------------------------------------------------

      const {
        data:
          hasQuotationUpdatePermission,
        error:
          quotationPermissionError,
      } =
        await supabase.rpc(
          "current_worker_has_permission",
          {
            p_permission_code:
              "quotations.update",
          },
        );

      if (
        quotationPermissionError
      ) {
        console.error(
          "Error comprobando permiso quotations.update:",
          quotationPermissionError,
        );

        return jsonResponse(
          {
            error:
              "No se ha podido verificar el permiso del trabajador",
          },
          500,
          corsHeaders,
        );
      }

      if (
        hasQuotationUpdatePermission !==
        true
      ) {
        return jsonResponse(
          {
            error:
              "Acceso denegado: se requiere el permiso quotations.update",
          },
          403,
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

      // Aceptamos quotation_id como nombre principal.
      // También aceptamos quotationId para compatibilidad.
      const quotationId =
        typeof bodyRecord.quotation_id ===
        "string"
          ? String(
              bodyRecord.quotation_id,
            ).trim()
          : typeof bodyRecord.quotationId ===
              "string"
            ? String(
                bodyRecord.quotationId,
              ).trim()
            : "";

      if (!quotationId) {
        return jsonResponse(
          {
            error:
              "quotation_id es obligatorio",
          },
          400,
          corsHeaders,
        );
      }

      const requestedAction =
        typeof bodyRecord.action ===
        "string"
          ? String(
              bodyRecord.action,
            ).trim()
          : "";

      // --------------------------------------------------------
      // 6. OBTENER PRESUPUESTO
      // --------------------------------------------------------

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
