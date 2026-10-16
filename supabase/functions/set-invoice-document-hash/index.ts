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

// ============================================================
// CLIENTE SERVICE ROLE
// ============================================================

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
// SHA-256
// ============================================================

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

// ============================================================
// PDF — UTILIDADES
// ============================================================

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

function safeText(
  value: unknown,
  fallback = "",
): string {
  const text = String(value ?? "").trim();
  return text || fallback;
}

function normalizePdfText(value: unknown): string {
  // Helvetica/WinAnsi no cubre todos los caracteres Unicode.
  // Conservamos los caracteres latinos habituales de facturación
  // y sustituimos únicamente los caracteres que no puede representar.
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

  return new Intl.NumberFormat("es-ES", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount) + " EUR";
}

function percentage(value: unknown): string {
  const amount = Number(value ?? 0);

  if (!Number.isFinite(amount)) {
    return "0,00 %";
  }

  return new Intl.NumberFormat("es-ES", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount) + " %";
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

    // Evitamos perder palabras extremadamente largas.
    if (
      font.widthOfTextAtSize(
        word,
        fontSize,
      ) <= maxWidth
    ) {
      current = word;
    } else {
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
  }

  if (current) {
    lines.push(current);
  }

  return lines.length > 0 ? lines : [""];
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

// ============================================================
// PDF — GENERACIÓN OFICIAL MODIRA
// ============================================================
//
// El PDF se genera exclusivamente a partir de la factura persistida
// y de sus snapshots fiscales. No recibe importes ni datos fiscales
// desde el frontend.
// ============================================================

async function generateInvoicePdf(
  invoice: Record<string, any>,
  originalInvoiceNumber: string | null,
): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();

  pdf.setTitle(
    `Factura ${safeText(invoice.numero_factura)}`,
  );
  pdf.setAuthor("Modira");
  pdf.setSubject("Factura emitida por Modira");
  pdf.setCreator("Modira");
  pdf.setProducer("Modira");

  const regularFont = await pdf.embedFont(
    StandardFonts.Helvetica,
  );

  const boldFont = await pdf.embedFont(
    StandardFonts.HelveticaBold,
  );

  let page = pdf.addPage([
    A4_WIDTH,
    A4_HEIGHT,
  ]);

  let y = A4_HEIGHT - MARGIN_TOP;

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

  page.drawText("FACTURA", {
    x: MARGIN_X,
    y: y - 28,
    size: 15,
    font: boldFont,
    color: DARK,
  });

  const invoiceNumber = normalizePdfText(
    safeText(
      invoice.numero_factura,
      "-",
    ),
  );

  const numberWidth =
    boldFont.widthOfTextAtSize(
      invoiceNumber,
      11,
    );

  page.drawText(
    invoiceNumber,
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
    `Emisión: ${dateEs(invoice.fecha_emision)}`,
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
    `Vencimiento: ${dateEs(invoice.fecha_vencimiento)}`,
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
  // PRESUPUESTO DE REFERENCIA
  // ----------------------------------------------------------

  const quotationNumber = safeText(
    invoice.quotation_number,
  );

  if (quotationNumber) {
    const referenceText =
      `Presupuesto de referencia: ${quotationNumber}`;

    page.drawText(
      normalizePdfText(referenceText),
      {
        x: MARGIN_X,
        y,
        size: 9,
        font: regularFont,
        color: MUTED,
      },
    );

    y -= 20;
  }
  // ----------------------------------------------------------
  // RECTIFICACIÓN
  // ----------------------------------------------------------

  if (invoice.rectifies_invoice_id) {
    page.drawRectangle({
      x: MARGIN_X,
      y: y - 32,
      width: contentWidth,
      height: 32,
      color: rgb(0.96, 0.97, 0.99),
      borderColor: LIGHT,
      borderWidth: 0.8,
    });

    page.drawText(
      "FACTURA RECTIFICATIVA",
      {
        x: MARGIN_X + 10,
        y: y - 13,
        size: 9,
        font: boldFont,
        color: ACCENT,
      },
    );

    const originalText =
      originalInvoiceNumber
        ? `Rectifica la factura ${originalInvoiceNumber}`
        : "Rectifica una factura anterior";

    page.drawText(
      normalizePdfText(
        originalText,
      ),
      {
        x: MARGIN_X + 10,
        y: y - 25,
        size: 8,
        font: regularFont,
        color: DARK,
      },
    );

    y -= 48;
  }

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
    "999999",
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

  issuerY = drawLabelValue(
    page,
    "Localidad",
    "ES",
    MARGIN_X,
    issuerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  const customerX =
    MARGIN_X + columnWidth + columnGap;

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
      invoice.customer_legal_name,
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
      invoice.customer_tax_id,
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
      invoice.customer_contact_name,
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
      invoice.customer_address,
      "-",
    ),
    customerX,
    customerY - 3,
    columnWidth,
    regularFont,
    boldFont,
  );

  const customerLocation = [
    safeText(invoice.customer_postal_code),
    safeText(invoice.customer_city),
    safeText(invoice.customer_province),
    safeText(invoice.customer_country),
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
  // CONTENIDO DE LA FACTURA
  // MISMA ESTRUCTURA VISUAL QUE EL PRESUPUESTO
  // ----------------------------------------------------------

  y = drawSectionTitle(
    page,
    "CONTENIDO DE LA FACTURA",
    MARGIN_X,
    y,
    contentWidth,
    boldFont,
  );

  // La factura guarda el contenido combinado en invoice.descripcion.
  // Separamos sus apartados para dibujarlos con el formato del presupuesto.

  const rawInvoiceDescription = safeText(
    invoice.descripcion,
    "",
  );

  // Extraer las notas antes de procesar los servicios.
  const notesMatch = rawInvoiceDescription.match(
    /Notas:\s*([\s\S]*)$/i,
  );

  const notes = notesMatch?.[1]?.trim() || "";

  const invoiceDescriptionWithoutNotes =
    rawInvoiceDescription.replace(
      /Notas:\s*[\s\S]*$/i,
      "",
    ).trim();

  // Extraer título.
  const titleMatch = invoiceDescriptionWithoutNotes.match(
    /Título:\s*([\s\S]*?)(?=\s*Descripción detallada:|\s*Servicios incluidos:|$)/i,
  );

  const invoiceTitle =
    titleMatch?.[1]?.trim() || "";

  // Extraer descripción detallada.
  const detailMatch = invoiceDescriptionWithoutNotes.match(
    /Descripción detallada:\s*([\s\S]*?)(?=\s*Servicios incluidos:|$)/i,
  );

  const invoiceDetail =
    detailMatch?.[1]?.trim() || "";

  // Extraer servicios.
  const servicesMatch = invoiceDescriptionWithoutNotes.match(
    /Servicios incluidos:\s*([\s\S]*)$/i,
  );

  const servicesText =
    servicesMatch?.[1]?.trim() || "";

  const invoiceServices: Array<{
    descripcion: string;
    cantidad: number;
    precio: number;
  }> = [];

  if (servicesText) {
    const serviceChunks = servicesText
      .split(/\s+-\s+(?=[^|\n]+\s*\|\s*Cantidad:)/i)
      .map((item) => item.replace(/^[-•]\s*/, "").trim())
      .filter(Boolean);

    for (const chunk of serviceChunks) {
      const serviceMatch = chunk.match(
        /^(.*?)\s*\|\s*Cantidad:\s*([^|]+?)\s*\|\s*Precio:\s*(.+)$/is,
      );

      if (!serviceMatch) {
        continue;
      }

      const serviceDescription =
        serviceMatch[1].trim();

      const quantityText =
        serviceMatch[2].trim();

      const priceText =
        serviceMatch[3].trim();

      const quantity = Number(
        quantityText.replace(",", "."),
      );

      // Admite importes como:
      // 54.00 EUR
      // 54,00 EUR
      // 1.234,56 EUR
      // 1,234.56 EUR
      let normalizedPrice = priceText.replace(
        /[^\d,.-]/g,
        "",
      );

      if (
        normalizedPrice.includes(",") &&
        normalizedPrice.includes(".")
      ) {
        if (
          normalizedPrice.lastIndexOf(",") >
          normalizedPrice.lastIndexOf(".")
        ) {
          normalizedPrice = normalizedPrice
            .replace(/\./g, "")
            .replace(",", ".");
        } else {
          normalizedPrice = normalizedPrice.replace(
            /,/g,
            "",
          );
        }
      } else if (normalizedPrice.includes(",")) {
        normalizedPrice = normalizedPrice.replace(
          ",",
          ".",
        );
      }

      const price = Number(normalizedPrice);

      if (
        !serviceDescription ||
        !Number.isFinite(quantity) ||
        !Number.isFinite(price)
      ) {
        continue;
      }

      invoiceServices.push({
        descripcion: serviceDescription,
        cantidad: quantity,
        precio: price,
      });
    }
  }

  // ----------------------------------------------------------
  // TÍTULO
  // Mismo formato que el presupuesto.
  // ----------------------------------------------------------

  if (invoiceTitle) {
    const titleLines = wrapText(
      invoiceTitle,
      boldFont,
      11,
      contentWidth,
    );

    for (const line of titleLines) {
      if (y < MARGIN_BOTTOM + 180) {
        page = pdf.addPage([
          A4_WIDTH,
          A4_HEIGHT,
        ]);

        y = A4_HEIGHT - MARGIN_TOP;
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
  }

  // ----------------------------------------------------------
  // DESCRIPCIÓN DETALLADA
  // Mismo formato que el presupuesto.
  // ----------------------------------------------------------

  if (invoiceDetail) {
    const descriptionBlocks =
      invoiceDetail.split(/\n\s*\n/);

    for (const block of descriptionBlocks) {
      const blockLines = block.split(/\n/);

      for (const rawLine of blockLines) {
        const lineText = rawLine.trim();

        if (!lineText) {
          y -= 6;
          continue;
        }

        const wrappedLines = wrapText(
          lineText,
          regularFont,
          9.5,
          contentWidth,
        );

        for (const line of wrappedLines) {
          if (y < MARGIN_BOTTOM + 180) {
            page = pdf.addPage([
              A4_WIDTH,
              A4_HEIGHT,
            ]);

            y = A4_HEIGHT - MARGIN_TOP;
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
  // SERVICIOS INCLUIDOS
  // Tabla con el mismo diseño que el presupuesto.
  // ----------------------------------------------------------

  const serviceSectionHeight =
    50 + invoiceServices.length * 30;

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

    y = A4_HEIGHT - MARGIN_TOP;
  }

  y = drawSectionTitle(
    page,
    "SERVICIOS INCLUIDOS",
    MARGIN_X,
    y,
    contentWidth,
    boldFont,
  );

  // Anchuras de las columnas: iguales que en el presupuesto.
  const descriptionWidth =
    contentWidth * 0.57;

  const quantityWidth =
    contentWidth * 0.13;

  const unitPriceWidth =
    contentWidth * 0.14;

  const totalWidth =
    contentWidth * 0.16;

  const serviceX = MARGIN_X;

  const quantityX =
    serviceX + descriptionWidth;

  const unitPriceX =
    quantityX + quantityWidth;

  const totalX =
    unitPriceX + unitPriceWidth;

  // Cabecera de la tabla.
  const drawInvoiceServicesHeader = () => {
  const headerY = y;

  // Descripción: alineada a la izquierda.
  page.drawText("Descripción", {
    x: serviceX,
    y: headerY,
    size: 8,
    font: boldFont,
    color: MUTED,
  });

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
      x: MARGIN_X + contentWidth,
      y,
    },
    thickness: 0.7,
    color: LIGHT,
  });

  y -= 17;
};

  drawInvoiceServicesHeader();

  for (
    let index = 0;
    index < invoiceServices.length;
    index++
  ) {
    const service = invoiceServices[index];

    const descriptionLines = wrapText(
      service.descripcion,
      regularFont,
      8.5,
      descriptionWidth - 5,
    );

    const rowHeight = Math.max(
      30,
      descriptionLines.length * 11 + 16,
    );

    // Si no cabe la siguiente fila, continuar en otra página.
    if (y < MARGIN_BOTTOM + 220) {
      page = pdf.addPage([
        A4_WIDTH,
        A4_HEIGHT,
      ]);

      y = A4_HEIGHT - MARGIN_TOP;

      y = drawSectionTitle(
        page,
        "SERVICIOS INCLUIDOS",
        MARGIN_X,
        y,
        contentWidth,
        boldFont,
      );

      drawInvoiceServicesHeader();
    }

    const textBlockHeight =
      descriptionLines.length * 11;

    const textStartY =
      y -
      (rowHeight - textBlockHeight) / 2 -
      2;

    // Descripción del servicio.
    for (
      let lineIndex = 0;
      lineIndex < descriptionLines.length;
      lineIndex++
    ) {
      page.drawText(
        normalizePdfText(
          descriptionLines[lineIndex],
        ),
        {
          x: serviceX,
          y: textStartY - lineIndex * 11,
          size: 8.5,
          font: regularFont,
          color: DARK,
        },
      );
    }

    // Cantidad.
    const quantityText =
      Number.isInteger(service.cantidad)
        ? String(service.cantidad)
        : service.cantidad.toLocaleString(
            "es-ES",
            {
              maximumFractionDigits: 2,
            },
          );

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

    // Precio unitario.
    const unitPriceText = money(service.precio);

    const unitPriceTextWidth =
      regularFont.widthOfTextAtSize(
        normalizePdfText(unitPriceText),
        8.5,
      );

    page.drawText(
      normalizePdfText(unitPriceText),
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

    // Importe de la línea: cantidad por precio.
    const lineTotalText = money(
      service.cantidad * service.precio,
    );

    const lineTotalTextWidth =
      regularFont.widthOfTextAtSize(
        normalizePdfText(lineTotalText),
        8.5,
      );

    page.drawText(
      normalizePdfText(lineTotalText),
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

    // Separador inferior de la fila.
    const rowBottom = y - rowHeight;

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

    y = rowBottom - 10;
  }

  if (invoiceServices.length === 0) {
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
  // Mismo formato que el presupuesto.
  // ----------------------------------------------------------

  if (notes) {
    if (y < MARGIN_BOTTOM + 200) {
      page = pdf.addPage([
        A4_WIDTH,
        A4_HEIGHT,
      ]);

      y = A4_HEIGHT - MARGIN_TOP;
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

    const noteBlocks = notes.split(/\n\s*\n/);

    for (const block of noteBlocks) {
      const noteLines = wrapText(
        block.trim(),
        regularFont,
        9,
        contentWidth,
      );

      for (const line of noteLines) {
        if (y < MARGIN_BOTTOM + 180) {
          page = pdf.addPage([
            A4_WIDTH,
            A4_HEIGHT,
          ]);

          y = A4_HEIGHT - MARGIN_TOP;
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

        y -= 13;
      }

      y -= 5;
    }
  }

  y -= 6;

  // ----------------------------------------------------------
  // RESUMEN ECONÓMICO
  // ----------------------------------------------------------

  const summaryHeight = 154;

  if (y < MARGIN_BOTTOM + summaryHeight) {
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

  let rowY = boxTop - 22;

  drawSummaryRow(
    "Base imponible",
    money(invoice.subtotal),
    rowY,
  );

  rowY -= 25;

  if (Boolean(invoice.iva_aplicado)) {
    drawSummaryRow(
      `IVA (${percentage(invoice.iva_porcentaje)})`,
      money(invoice.iva_importe),
      rowY,
    );
  } else {
    drawSummaryRow(
      "IVA",
      "No aplicado",
      rowY,
    );
  }

  rowY -= 25;

  if (Boolean(invoice.irpf_aplicado)) {
    drawSummaryRow(
      `IRPF (${percentage(invoice.irpf_porcentaje)})`,
      `- ${money(invoice.irpf_importe)}`,
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
    "Total factura",
    money(invoice.monto),
    rowY,
    true,
  );

  rowY -= 29;

  drawSummaryRow(
    "IMPORTE A PAGAR",
    money(invoice.importe_a_pagar),
    rowY,
    true,
  );

  y =
    boxBottom -
    26;

  // ----------------------------------------------------------
  // MOTIVO DE RECTIFICACIÓN
  // ----------------------------------------------------------

  if (invoice.rectifies_invoice_id) {
    y = drawSectionTitle(
      page,
      "MOTIVO DE RECTIFICACIÓN",
      MARGIN_X,
      y,
      contentWidth,
      boldFont,
    );

    const reason =
      safeText(
        invoice.rectification_reason,
        "Sin motivo indicado",
      );

    const reasonLines =
      wrapText(
        reason,
        regularFont,
        9,
        contentWidth,
      );

    for (const line of reasonLines) {
      if (y < MARGIN_BOTTOM + 40) {
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

    y -= 12;
  }

  // ----------------------------------------------------------
  // PIE
  // ----------------------------------------------------------

  page.drawLine({
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

  page.drawText(
    "Documento generado automáticamente por Modira.",
    {
      x: MARGIN_X,
      y: MARGIN_BOTTOM - 24,
      size: 7.5,
      font: regularFont,
      color: MUTED,
    },
  );

  page.drawText(
    `Factura ${invoiceNumber}`,
    {
      x:
        A4_WIDTH -
        MARGIN_X -
        100,
      y: MARGIN_BOTTOM - 24,
      size: 7.5,
      font: regularFont,
      color: MUTED,
    },
  );

  const pdfBytes =
    await pdf.save();

  return pdfBytes;
}

// ============================================================
// OBTENER FACTURA
// ============================================================

async function getInvoice(
  invoiceId: string,
) {
  const {
    data,
    error,
  } = await supabaseAdmin
    .from("invoices")
    .select(
      [
        "id",
        "user_id",
        "company_id",
        "project_id",
        "client_id",
        "quotation_id",
        "numero_factura",
        "monto",
        "estado",
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
        "importe_a_pagar",
        "stripe_invoice_id",
        "document_path",
        "document_sha256",
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
        "rectifies_invoice_id",
        "rectification_reason",
        "rectification_customer_data_source",
      ].join(", "),
    )
    .eq("id", invoiceId)
    .maybeSingle();

  if (error) {
    throw new Error(
      `No se ha podido obtener la factura: ${error.message}`,
    );
  }

  if (!data) {
    throw new Error(
      "La factura no existe",
    );
  }

  return data as Record<string, any>;
}

// ============================================================
// OBTENER NÚMERO DE LA FACTURA ORIGINAL
// ============================================================

async function getOriginalInvoiceNumber(
  rectifiesInvoiceId: string | null,
): Promise<string | null> {
  if (!rectifiesInvoiceId) {
    return null;
  }

  const {
    data,
    error,
  } = await supabaseAdmin
    .from("invoices")
    .select("numero_factura")
    .eq("id", rectifiesInvoiceId)
    .maybeSingle();

  if (error) {
    throw new Error(
      `No se ha podido obtener la factura original: ${error.message}`,
    );
  }

  return data?.numero_factura
    ? String(data.numero_factura)
    : null;
}

// ============================================================
// COMPROBAR SNAPSHOT FISCAL
// ============================================================
//
// Las facturas nuevas creadas mediante 072 ya contienen estos datos.
// Para no bloquear innecesariamente facturas antiguas que todavía no
// tengan snapshot completo, se utiliza la información fiscal actual
// como fallback únicamente cuando sea necesario para generar un PDF
// de una factura todavía no documentada.
// ============================================================

async function completeFiscalFallback(
  invoice: Record<string, any>,
): Promise<Record<string, any>> {
  const completed = {
    ...invoice,
  };

  const issuerMissing =
    !safeText(invoice.issuer_legal_name) ||
    !safeText(invoice.issuer_tax_id) ||
    !safeText(invoice.issuer_address) ||
    !safeText(invoice.issuer_postal_code) ||
    !safeText(invoice.issuer_city);

  if (issuerMissing && invoice.company_id) {
    const {
      data: company,
      error,
    } = await supabaseAdmin
      .from("companies")
      .select(
        "legal_name, company_name, cif_vat, address, postal_code, city, province, country",
      )
      .eq("id", invoice.company_id)
      .maybeSingle();

    if (error) {
      throw new Error(
        `No se han podido obtener los datos fiscales del emisor: ${error.message}`,
      );
    }

    if (company) {
      completed.issuer_legal_name =
        safeText(
          invoice.issuer_legal_name,
          safeText(
            company.legal_name,
            safeText(
              company.company_name,
              "-",
            ),
          ),
        );

      completed.issuer_tax_id =
        safeText(
          invoice.issuer_tax_id,
          safeText(company.cif_vat, "-"),
        );

      completed.issuer_address =
        safeText(
          invoice.issuer_address,
          safeText(company.address, "-"),
        );

      completed.issuer_postal_code =
        safeText(
          invoice.issuer_postal_code,
          safeText(company.postal_code, "-"),
        );

      completed.issuer_city =
        safeText(
          invoice.issuer_city,
          safeText(company.city, "-"),
        );

      completed.issuer_province =
        safeText(
          invoice.issuer_province,
          safeText(company.province, ""),
        );

      completed.issuer_country =
        safeText(
          invoice.issuer_country,
          safeText(company.country, "ES"),
        );
    }
  }

  // ==========================================================
  // COMPLETAR LOS DATOS DEL DESTINATARIO SIN CONFUNDIRLOS
  // CON LOS DEL EMISOR
  // ==========================================================
  //
  // issuer_*   = datos del emisor.
  // customer_* = datos del destinatario.
  //
  // En una rectificativa:
  // - original_invoice: usar los datos de la factura original.
  // - current_company: usar los datos fiscales actuales del cliente.
  //
  // Nunca copiar issuer_* a customer_*.
  // ==========================================================

  let customerFallback: Record<string, any> = {};

  if (invoice.rectifies_invoice_id) {
      const {
      data: originalData,
      error: originalError,
    } = await supabaseAdmin
      .from("invoices")
      .select(
        [
          "id",
          "company_id",
          "client_id",
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
      .eq("id", invoice.rectifies_invoice_id)
      .maybeSingle();

    if (originalError) {
      throw new Error(
        `No se han podido recuperar los datos de la factura original: ${originalError.message}`,
      );
    }

    if (!originalData) {
      throw new Error(
        "No se encuentra la factura original de la rectificativa.",
      );
    }

    const original: Record<string, any> = originalData;
    if (original.company_id !== invoice.company_id) {
      throw new Error(
        "La factura original no pertenece a la misma empresa.",
      );
    }

    if (
      invoice.rectification_customer_data_source ===
      "original_invoice"
    ) {
      customerFallback = {
        customer_legal_name: original.customer_legal_name,
        customer_tax_id: original.customer_tax_id,
        customer_address: original.customer_address,
        customer_postal_code: original.customer_postal_code,
        customer_city: original.customer_city,
        customer_province: original.customer_province,
        customer_country: original.customer_country,
        customer_contact_name: original.customer_contact_name,
      };
    } else if (
      invoice.rectification_customer_data_source ===
      "current_company"
    ) {
      if (!original.client_id) {
        throw new Error(
          "La factura original no tiene un cliente asociado para recuperar sus datos fiscales actuales.",
        );
      }

      const {
        data: client,
        error: clientError,
      } = await supabaseAdmin
        .from("clients")
        .select(
          "company_id, empresa, nombre, cif_vat, direccion, codigo_postal, ciudad, provincia, pais",
        )
        .eq("id", original.client_id)
        .maybeSingle();

      if (clientError) {
        throw new Error(
          `No se han podido recuperar los datos actuales del cliente: ${clientError.message}`,
        );
      }

      if (client == null) {
        throw new Error(
          "No se encuentra el cliente asociado a la factura original.",
        );
      }

      if (client.company_id !== original.company_id) {
        throw new Error(
          "El cliente no pertenece a la empresa de la factura original.",
        );
      }

      customerFallback = {
        customer_legal_name:
          client.empresa?.trim() ||
          client.nombre?.trim() ||
          null,
        customer_tax_id: client.cif_vat,
        customer_address: client.direccion,
        customer_postal_code: client.codigo_postal,
        customer_city: client.ciudad,
        customer_province: client.provincia,
        customer_country: client.pais || "ES",
        customer_contact_name: client.nombre,
      };
    }
  } else if (invoice.client_id) {
    const {
      data: client,
      error: clientError,
    } = await supabaseAdmin
      .from("clients")
      .select(
        "company_id, empresa, nombre, cif_vat, direccion, codigo_postal, ciudad, provincia, pais",
      )
      .eq("id", invoice.client_id)
      .maybeSingle();

    if (clientError) {
      throw new Error(
        `No se han podido recuperar los datos del cliente: ${clientError.message}`,
      );
    }

    if (client && client.company_id === invoice.company_id) {
      customerFallback = {
        customer_legal_name:
          client.empresa?.trim() ||
          client.nombre?.trim() ||
          null,
        customer_tax_id: client.cif_vat,
        customer_address: client.direccion,
        customer_postal_code: client.codigo_postal,
        customer_city: client.ciudad,
        customer_province: client.provincia,
        customer_country: client.pais || "ES",
        customer_contact_name: client.nombre,
      };
    }
  }

    // ==========================================================
  // DATOS DEL CLIENTE PARA EL PDF
  // ==========================================================
  //
  // Se priorizan los campos issuer_* de la factura,
  // replicando el comportamiento actual de presupuestos.
  //
  // Si no están disponibles, se utilizan los datos recuperados
  // del cliente asociado y, finalmente, los customer_* guardados.
  //
  // ==========================================================

  completed.customer_legal_name =
    safeText(
      invoice.issuer_legal_name,
      safeText(
        customerFallback.customer_legal_name,
        safeText(invoice.customer_legal_name, "-"),
      ),
    );

  completed.customer_tax_id =
    safeText(
      invoice.issuer_tax_id,
      safeText(
        customerFallback.customer_tax_id,
        safeText(invoice.customer_tax_id, "-"),
      ),
    );

  completed.customer_address =
    safeText(
      invoice.issuer_address,
      safeText(
        customerFallback.customer_address,
        safeText(invoice.customer_address, "-"),
      ),
    );

  completed.customer_postal_code =
    safeText(
      invoice.issuer_postal_code,
      safeText(
        customerFallback.customer_postal_code,
        safeText(invoice.customer_postal_code, ""),
      ),
    );

  completed.customer_city =
    safeText(
      invoice.issuer_city,
      safeText(
        customerFallback.customer_city,
        safeText(invoice.customer_city, ""),
      ),
    );

  completed.customer_province =
    safeText(
      invoice.issuer_province,
      safeText(
        customerFallback.customer_province,
        safeText(invoice.customer_province, ""),
      ),
    );

  completed.customer_country =
    safeText(
      invoice.issuer_country,
      safeText(
        customerFallback.customer_country,
        safeText(invoice.customer_country, "ES"),
      ),
    );

  completed.customer_contact_name =
    safeText(
      customerFallback.customer_contact_name,
      safeText(invoice.customer_contact_name, ""),
    );

  return completed;
}
// ============================================================
// FINALIZAR DOCUMENTO BACKEND
// ============================================================

async function finalizeBackendDocument(
  invoiceId: string,
  documentPath: string,
  documentSha256: string,
) {
  const {
    data,
    error,
  } = await supabaseAdmin.rpc(
    "finalize_invoice_backend_document",
    {
      p_invoice_id: invoiceId,
      p_document_path: documentPath,
      p_document_sha256: documentSha256,
    },
  );

  if (error) {
    throw new Error(
      `No se ha podido finalizar el documento de factura: ${error.message}`,
    );
  }

  return data;
}

// ============================================================
// GENERAR Y FINALIZAR PDF AUTOMÁTICO
// ============================================================

async function generateAndFinalizeInvoiceDocument(
  invoice: Record<string, any>,
) {
  const invoiceId =
    String(invoice.id);

  const invoiceNumber =
    safeText(
      invoice.numero_factura,
    );

  if (!invoiceNumber) {
    throw new Error(
      "La factura no tiene número de factura",
    );
  }

  // Una factura aceptada no puede regenerar/sustituir su documento.
  if (
    invoice.document_path &&
    invoice.document_sha256
  ) {
    return {
      invoice,
      document_path:
        invoice.document_path,
      document_sha256:
        invoice.document_sha256,
      already_finalized: true,
    };
  }

  if (invoice.document_path) {
    throw new Error(
      "La factura ya tiene un documento asociado. Para mantener la compatibilidad con documentos existentes, utiliza la acción de hash del documento en lugar de regenerar el PDF.",
    );
  }

  const completeInvoice =
    await completeFiscalFallback(
      invoice,
    );

  const originalInvoiceNumber =
    await getOriginalInvoiceNumber(
      completeInvoice.rectifies_invoice_id
        ? String(
            completeInvoice.rectifies_invoice_id,
          )
        : null,
    );

  const pdfBytes =
    await generateInvoicePdf(
      completeInvoice,
      originalInvoiceNumber,
    );

  if (
    pdfBytes.byteLength <= 0
  ) {
    throw new Error(
      "El PDF generado está vacío",
    );
  }

  const MAX_FILE_SIZE =
    20 * 1024 * 1024;

  if (
    pdfBytes.byteLength >
    MAX_FILE_SIZE
  ) {
    throw new Error(
      "El PDF generado supera el tamaño máximo permitido",
    );
  }

  const documentPath =
    `${invoiceNumber}.pdf`;

  // La ruta es deliberadamente la misma que valida
  // finalize_invoice_backend_document() de la migración 071.
  const {
    error: uploadError,
  } = await supabaseAdmin.storage
    .from("invoices")
    .upload(
      documentPath,
      pdfBytes,
      {
        contentType: "application/pdf",
        cacheControl: "3600",
        upsert: false,
      },
    );

  if (uploadError) {
    // Si el objeto ya existe, intentamos reutilizarlo únicamente
    // si pertenece a esta factura y todavía no está finalizado.
    if (
      /already exists|duplicate|exists/i.test(
        uploadError.message,
      )
    ) {
      const {
        data: existingFile,
        error: downloadError,
      } = await supabaseAdmin.storage
        .from("invoices")
        .download(documentPath);

      if (downloadError || !existingFile) {
        throw new Error(
          `El PDF ya existe pero no se ha podido recuperar: ${downloadError?.message ?? "documento no disponible"}`,
        );
      }

      const existingBuffer =
        await existingFile.arrayBuffer();

      const existingHash =
        await calculateSha256(
          existingBuffer,
        );

      // No sustituimos silenciosamente un objeto que ya exista
      // con contenido diferente.
      const newHash =
        await calculateSha256(
          toArrayBuffer(pdfBytes),
        );

      if (
        existingHash !== newHash
      ) {
        throw new Error(
          "Ya existe un PDF con el mismo número de factura pero su contenido no coincide con el documento que se acaba de generar. No se ha sustituido el documento.",
        );
      }

      const finalized =
        await finalizeBackendDocument(
          invoiceId,
          documentPath,
          existingHash,
        );

      return {
        invoice: finalized,
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

  const pdfBuffer =
    toArrayBuffer(pdfBytes);

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

  const finalized =
    await finalizeBackendDocument(
      invoiceId,
      documentPath,
      documentSha256,
    );

  return {
    invoice: finalized,
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
// HASH LEGACY DE DOCUMENTOS EXISTENTES
// ============================================================
//
// Se conserva para no romper el flujo actual de facturas que ya
// tienen un PDF asociado manualmente. Las nuevas facturas pueden
// utilizar exactamente el mismo endpoint sin subir un PDF.
// ============================================================

async function hashExistingInvoiceDocument(
  invoice: Record<string, any>,
  authenticatedClient: SupabaseClient,
) {
  const invoiceId =
    String(invoice.id);

  const documentPath =
    String(
      invoice.document_path ?? "",
    ).trim();

  if (!documentPath) {
    throw new Error(
      "La factura no tiene un documento asociado",
    );
  }

  const {
    data: file,
    error: downloadError,
  } = await supabaseAdmin.storage
    .from("invoices")
    .download(documentPath);

  if (downloadError) {
    throw new Error(
      `No se ha podido obtener el PDF asociado a la factura: ${downloadError.message}`,
    );
  }

  if (!file) {
    throw new Error(
      "El PDF asociado no existe en Storage",
    );
  }

  const MAX_FILE_SIZE =
    20 * 1024 * 1024;

  if (file.size <= 0) {
    throw new Error(
      "El documento PDF está vacío",
    );
  }

  if (
    file.size >
    MAX_FILE_SIZE
  ) {
    throw new Error(
      "El documento PDF supera el tamaño máximo permitido",
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

  // Si el documento ya está finalizado por backend, no intentamos
  // sustituirlo. La RPC de compatibilidad únicamente registra el hash
  // de documentos que ya estaban asociados.
  const {
    data: updatedInvoice,
    error: hashError,
  } = await authenticatedClient.rpc(
    "set_invoice_document_hash",
    {
      p_invoice_id: invoiceId,
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
    invoice: updatedInvoice,
    document_path:
      documentPath,
    document_sha256:
      documentSha256,
  };
}

// ============================================================
// EDGE FUNCTION
// ============================================================

Deno.serve(async (req) => {
  const corsHeaders =
    getCorsHeaders(
      req.headers.get("Origin"),
    );

  // ==========================================================
  // OPTIONS
  // ==========================================================

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  // ==========================================================
  // MÉTODO
  // ==========================================================

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        error: "Método no permitido",
      }),
      {
        status: 405,
        headers: {
          ...corsHeaders,
          "Content-Type":
            "application/json",
        },
      },
    );
  }

  try {
    // ========================================================
    // 1. AUTORIZACIÓN
    // ========================================================

    const authHeader =
      req.headers.get(
        "Authorization",
      );

    if (!authHeader) {
      return new Response(
        JSON.stringify({
          error: "No autenticado",
        }),
        {
          status: 401,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    // ========================================================
    // 2. CLIENTE CON SESIÓN DEL USUARIO
    // ========================================================

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
        },
      );

    // ========================================================
    // 3. USUARIO ACTUAL
    // ========================================================

    const {
      data: {
        user,
      },
      error: userError,
    } =
      await supabase.auth.getUser();

    if (userError || !user) {
      console.error(
        "Error verificando usuario:",
        userError,
      );

      return new Response(
        JSON.stringify({
          error:
            "Sesión no válida",
        }),
        {
          status: 401,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    // ========================================================
    // 4. COMPROBAR QUE ES WORKER
    // ========================================================

    const {
      data: isWorker,
      error: workerError,
    } =
      await supabase.rpc(
        "current_user_is_worker",
      );

    if (workerError) {
      console.error(
        "Error comprobando trabajador:",
        workerError,
      );

      return new Response(
        JSON.stringify({
          error:
            "No se ha podido verificar el permiso de trabajador",
        }),
        {
          status: 500,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    if (!isWorker) {
      return new Response(
        JSON.stringify({
          error:
            "Acceso denegado: se requiere un trabajador activo",
        }),
        {
          status: 403,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    // ========================================================
    // 4B. PERMISO RBAC
    // ========================================================

    const {
      data:
        hasInvoiceUpdatePermission,
      error:
        invoicePermissionError,
    } =
      await supabase.rpc(
        "current_worker_has_permission",
        {
          p_permission_code:
            "invoices.update",
        },
      );

    if (invoicePermissionError) {
      console.error(
        "Error comprobando permiso invoices.update:",
        invoicePermissionError,
      );

      return new Response(
        JSON.stringify({
          error:
            "No se ha podido verificar el permiso del trabajador",
        }),
        {
          status: 500,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    if (
      hasInvoiceUpdatePermission !==
      true
    ) {
      return new Response(
        JSON.stringify({
          error:
            "Acceso denegado: se requiere el permiso invoices.update",
        }),
        {
          status: 403,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    // ========================================================
    // 5. BODY
    // ========================================================

    let body: unknown;

    try {
      body = await req.json();
    } catch {
      return new Response(
        JSON.stringify({
          error:
            "El cuerpo de la petición no es JSON válido",
        }),
        {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    const bodyRecord =
      (body as Record<
        string,
        unknown
      >) ?? {};

    const invoiceId =
      typeof bodyRecord.invoice_id ===
      "string"
        ? String(
            bodyRecord.invoice_id,
          ).trim()
        : "";

    if (!invoiceId) {
      return new Response(
        JSON.stringify({
          error:
            "invoice_id es obligatorio",
        }),
        {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    const requestedAction =
      typeof bodyRecord.action ===
      "string"
        ? String(
            bodyRecord.action,
          ).trim()
        : "";

    // ========================================================
    // 6. OBTENER FACTURA
    // ========================================================

    const invoice =
      await getInvoice(
        invoiceId,
      );

    // ========================================================
    // 7. GENERACIÓN AUTOMÁTICA
    // ========================================================
    //
    // Nuevo comportamiento:
    // - si no hay documento, se genera el PDF Modira;
    // - se guarda en invoices/<numero_factura>.pdf;
    // - se calcula SHA-256 server-side;
    // - se finaliza mediante la RPC 071.
    //
    // Si action está vacío, la generación automática es también el
    // comportamiento por defecto cuando no existe documento.
    // ========================================================

    if (
      requestedAction ===
        "generate_invoice_document" ||
      (
        !requestedAction &&
        !invoice.document_path
      )
    ) {
      const result =
        await generateAndFinalizeInvoiceDocument(
          invoice,
        );

      return new Response(
        JSON.stringify({
          success: true,
          mode: "automatic_pdf",
          invoice_id: invoiceId,
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
          invoice:
            result.invoice,
        }),
        {
          status: 200,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    // ========================================================
    // 8. COMPATIBILIDAD — HASH DE PDF EXISTENTE
    // ========================================================
    //
    // Si el frontend actual continúa invocando esta Edge Function
    // después de subir manualmente un PDF, ese flujo sigue funcionando.
    // ========================================================

    if (
      requestedAction ===
        "set_invoice_document_hash" ||
      invoice.document_path
    ) {
      const result =
        await hashExistingInvoiceDocument(
          invoice,
          supabase,
        );

      return new Response(
        JSON.stringify({
          success: true,
          mode: "existing_document_hash",
          invoice_id: invoiceId,
          document_path:
            result.document_path,
          document_sha256:
            result.document_sha256,
          invoice:
            result.invoice,
        }),
        {
          status: 200,
          headers: {
            ...corsHeaders,
            "Content-Type":
              "application/json",
          },
        },
      );
    }

    // ========================================================
    // 9. ESTADO IMPOSIBLE
    // ========================================================

    return new Response(
      JSON.stringify({
        error:
          "No se ha podido determinar la operación documental de la factura",
      }),
      {
        status: 409,
        headers: {
          ...corsHeaders,
          "Content-Type":
            "application/json",
        },
      },
    );
  } catch (error) {
    console.error(
      "invoice-document error:",
      error,
    );

    const message =
      error instanceof Error
        ? error.message
        : "Error interno al procesar el documento de la factura";

    return new Response(
      JSON.stringify({
        error: message,
      }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type":
            "application/json",
        },
      },
    );
  }
});
