import Stripe from "npm:stripe@18.5.0";
import { createClient } from "npm:@supabase/supabase-js@2";

// ============================================================
// STRIPE
// ============================================================

const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");

if (!stripeSecretKey) {
  throw new Error("STRIPE_SECRET_KEY no está configurada");
}

const stripe = new Stripe(stripeSecretKey, {
  apiVersion: "2025-08-27.basil",
});

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
// CORS
// ============================================================

function getAllowedOrigins(): Set<string> {
  const raw =
    Deno.env.get("MODIRA_ALLOWED_ORIGINS") ?? "";

  const origins = raw
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

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
// ACKNOWLEDGEMENT
// ============================================================

const INVOICE_DOCUMENT_ACKNOWLEDGEMENT_VERSION =
  "invoice_document_acknowledgement_v1";

// ============================================================
// RESPUESTA JSON
// ============================================================

function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
  corsHeaders: Record<string, string> = {},
) {
  return new Response(
    JSON.stringify(body),
    {
      status,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
      },
    },
  );
}

// ============================================================
// PREPARAR DESCRIPCIÓN DE FACTURA PARA STRIPE
// ============================================================

const formatInvoiceDescriptionForStripe = (
  description: string | null,
  invoiceNumber: string,
  dueDate: string | null,
): string => {
  if (!description || !description.trim()) {
    return dueDate
      ? `Pago de la factura ${invoiceNumber}
Vencimiento: ${new Date(
          dueDate,
        ).toLocaleDateString("es-ES")}`
      : `Pago de la factura ${invoiceNumber}`;
  }

  const text = description.trim();

  const titleMatch = text.match(
    /Título:\s*(.*?)(?=\n\s*\n|Descripción detallada:|Servicios incluidos:|Notas:|$)/i,
  );

  const detailMatch = text.match(
    /Descripción detallada:\s*(.*?)(?=\n\s*\n|Servicios incluidos:|Notas:|$)/i,
  );

  const servicesMatch = text.match(
    /Servicios incluidos:\s*([\s\S]*?)(?=\n\s*\nNotas:|Notas:|$)/i,
  );

  const notesMatch = text.match(
    /Notas:\s*([\s\S]*?)$/i,
  );

  const title = titleMatch?.[1]?.trim() || "";
  const detail = detailMatch?.[1]?.trim() || "";
  const services = servicesMatch?.[1]?.trim() || "";
  const notes = notesMatch?.[1]?.trim() || "";

  const sections: string[] = [];

  if (title) {
    sections.push(`Título: ${title}`);
  }

  if (detail) {
    sections.push(`Descripción: ${detail}`);
  }

  if (services) {
    const formattedServices = services
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => {
        const serviceMatch = line.match(
          /^-\s*(.*?)\s*\|\s*Cantidad:\s*([^|]+)\s*\|\s*Precio:\s*(.+)$/i,
        );

        if (serviceMatch) {
          return `• ${serviceMatch[1].trim()}`;
        }

        return line.replace(/^-\s*/, "• ");
      })
      .join("\n");

    if (formattedServices) {
      sections.push(
        `Servicios incluidos:\n${formattedServices}`,
      );
    }
  }

  if (notes) {
    sections.push(`Notas: ${notes}`);
  }

  if (dueDate) {
    sections.push(
      `Vencimiento: ${new Date(
        dueDate,
      ).toLocaleDateString("es-ES")}`,
    );
  }

  if (sections.length === 0) {
    return dueDate
      ? `${text}\nVencimiento: ${new Date(
          dueDate,
        ).toLocaleDateString("es-ES")}`
      : text;
  }

  return sections.join("\n\n");
};

// ============================================================
// OBTENER TÍTULO DE FACTURA
// ============================================================

const getInvoiceTitle = (
  description: string | null,
  invoiceNumber: string,
): string => {
  const text = description?.trim() || "";

  const titleMatch = text.match(
    /Título:\s*(.*?)(?=\n|Descripción detallada:|Servicios incluidos:|Notas:|$)/i,
  );

  const title = titleMatch?.[1]?.trim();

  return title || `Factura ${invoiceNumber}`;
};

// ============================================================
// LIMITAR TEXTOS PARA STRIPE
// ============================================================

const truncateForStripe = (
  value: string,
  maxLength: number,
): string => {
  const text = value.trim();

  if (text.length <= maxLength) {
    return text;
  }

  return `${text.slice(0, maxLength - 3).trim()}...`;
};

// ============================================================
// EDGE FUNCTION
// ============================================================

Deno.serve(async (req) => {
  const corsHeaders =
    getCorsHeaders(
      req.headers.get("Origin"),
    );

  // ==========================================================
  // 1. CORS
  // ==========================================================

  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders,
    });
  }

  // ==========================================================
  // 2. SOLO POST
  // ==========================================================

  if (req.method !== "POST") {
    return jsonResponse(
      {
        error: "Método no permitido",
      },
      405,
      corsHeaders,
    );
  }

  try {
    // ========================================================
    // 3. AUTHORIZATION
    // ========================================================

    const authHeader =
      req.headers.get("Authorization");

    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse(
        {
          error: "No autenticado",
        },
        401,
        corsHeaders,
      );
    }

    const accessToken =
      authHeader.substring("Bearer ".length).trim();

    if (!accessToken) {
      return jsonResponse(
        {
          error: "No autenticado",
        },
        401,
        corsHeaders,
      );
    }

    // ========================================================
    // 4. CLIENTE SUPABASE CON TOKEN DEL USUARIO
    // ========================================================

    const supabase = createClient(
      supabaseUrl,
      supabaseAnonKey,
      {
        global: {
          headers: {
            Authorization: `Bearer ${accessToken}`,
          },
        },
        auth: {
          persistSession: false,
          autoRefreshToken: false,
        },
      },
    );

    // ========================================================
    // 5. CLIENTE SERVICE ROLE
    // ========================================================

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

    // ========================================================
    // 6. USUARIO ACTUAL
    // ========================================================

    const {
      data: {
        user,
      },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError || !user) {
      console.error(
        "[create-checkout-session] Error verificando usuario:",
        userError,
      );

      return jsonResponse(
        {
          error: "Sesión no válida",
        },
        401,
        corsHeaders,
      );
    }

    console.log(
      "[create-checkout-session] Usuario autenticado:",
      user.id,
    );

    // ========================================================
    // 7. OBTENER PERFIL
    // ========================================================

    const {
      data: profile,
      error: profileError,
    } = await supabaseAdmin
      .from("profiles")
      .select("id, status, rol")
      .eq("id", user.id)
      .maybeSingle();

    if (profileError) {
      console.error(
        "[create-checkout-session] Error obteniendo perfil:",
        profileError,
      );

      return jsonResponse(
        {
          error:
            "No se ha podido verificar el estado de la cuenta",
        },
        500,
        corsHeaders,
      );
    }

    // ========================================================
    // 8. PERFIL OBLIGATORIO
    // ========================================================

    if (!profile) {
      console.error(
        "[create-checkout-session] No existe perfil para:",
        user.id,
      );

      return jsonResponse(
        {
          error:
            "No se ha podido verificar la cuenta",
        },
        403,
        corsHeaders,
      );
    }

    // ========================================================
    // 9. SOLO CLIENTES
    // ========================================================
    //
    // Esta Edge Function crea un pago para una factura del
    // cliente autenticado.
    //
    // Un worker no debe utilizar esta vía.
    //
    // No se utiliza ningún permiso worker aquí porque pagar
    // una factura es una acción propia del cliente.
    // ========================================================

    if (profile.rol !== "user") {
      console.warn(
        "[create-checkout-session] Intento de checkout desde una cuenta no cliente:",
        {
          userId: user.id,
          rol: profile.rol,
        },
      );

      return jsonResponse(
        {
          error:
            "Esta operación solo está disponible para cuentas de cliente",
        },
        403,
        corsHeaders,
      );
    }

    // ========================================================
    // 10. CUENTA ACTIVA
    // ========================================================

    const profileStatus = String(
      profile.status ?? "",
    )
      .trim()
      .toLowerCase();

    if (profileStatus !== "active") {
      console.warn(
        "[create-checkout-session] Cuenta no activa:",
        {
          userId: user.id,
          status: profile.status,
        },
      );

      return jsonResponse(
        {
          error:
            "Tu cuenta no está activa y no puede realizar pagos",
        },
        403,
        corsHeaders,
      );
    }

    // ========================================================
    // 11. BODY
    // ========================================================

    let body: unknown;

    try {
      body = await req.json();
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

    // ========================================================
    // 12. INVOICE ID
    // ========================================================

    const invoiceId =
      typeof (body as Record<string, unknown>)
        ?.invoice_id === "string"
        ? String(
            (body as Record<string, unknown>)
              .invoice_id,
          ).trim()
        : "";

    if (!invoiceId) {
      return jsonResponse(
        {
          error: "invoice_id es obligatorio",
        },
        400,
        corsHeaders,
      );
    }

    console.log(
      "[create-checkout-session] Solicitud de Checkout:",
      {
        invoiceId,
        userId: user.id,
      },
    );

    // ========================================================
    // 13. OBTENER FACTURA
    // ========================================================
    //
    // Se mantiene la protección doble:
    //
    //   RLS + user_id
    //
    // El frontend no puede decidir qué factura pagar.
    // ========================================================

    const {
      data: invoice,
      error: invoiceError,
    } = await supabase
      .from("invoices")
      .select(
        `
          id,
          user_id,
          company_id,
          numero_factura,
          estado,
          importe_a_pagar,
          descripcion,
          fecha_vencimiento,
          document_path,
          document_sha256
        `,
      )
      .eq("id", invoiceId)
      .eq("user_id", user.id)
      .maybeSingle();

    if (invoiceError) {
      console.error(
        "[create-checkout-session] Error obteniendo factura:",
        invoiceError,
      );

      return jsonResponse(
        {
          error:
            "No se ha podido obtener la factura",
          code:
            invoiceError.code ??
            "INVOICE_QUERY_ERROR",
        },
        500,
        corsHeaders,
      );
    }

    // ========================================================
    // 14. FACTURA NO EXISTE / NO PERTENECE AL CLIENTE
    // ========================================================

    if (!invoice) {
      return jsonResponse(
        {
          error:
            "La factura no existe o no tienes acceso a ella",
        },
        404,
        corsHeaders,
      );
    }

    // ========================================================
    // 15. ESTADO DE LA FACTURA
    // ========================================================

    const normalizedStatus = String(
      invoice.estado ?? "",
    )
      .trim()
      .toLowerCase();

    if (normalizedStatus === "pagada") {
      return jsonResponse(
        {
          error: "La factura ya está pagada",
        },
        409,
        corsHeaders,
      );
    }

    if (normalizedStatus === "cancelada") {
      return jsonResponse(
        {
          error:
            "Esta factura está cancelada y no se puede pagar",
        },
        409,
        corsHeaders,
      );
    }

    // ========================================================
    // 16. DOCUMENTO PDF OBLIGATORIO
    // ========================================================

    const documentPath =
      String(
        invoice.document_path ?? "",
      ).trim();

    if (!documentPath) {
      return jsonResponse(
        {
          error:
            "Esta factura no tiene un documento PDF asociado y no puede iniciar el pago.",
          code:
            "INVOICE_DOCUMENT_REQUIRED",
        },
        409,
        corsHeaders,
      );
    }

    // ========================================================
    // 17. SHA-256 OBLIGATORIO
    // ========================================================

    const documentSha256 =
      String(
        invoice.document_sha256 ?? "",
      )
        .trim()
        .toLowerCase();

    if (
      !/^[0-9a-f]{64}$/.test(
        documentSha256,
      )
    ) {
      return jsonResponse(
        {
          error:
            "El documento de esta factura todavía no está validado. No se puede iniciar el pago.",
          code:
            "INVOICE_DOCUMENT_HASH_REQUIRED",
        },
        409,
        corsHeaders,
      );
    }

    // ========================================================
    // 18. COMPROBAR ACEPTACIÓN DEL DOCUMENTO
    // ========================================================
    //
    // Se comprueba server-side.
    //
    // Deben coincidir:
    //
    //   invoice_id
    //   user_id
    //   document_path
    //   document_sha256
    //   acknowledgement_text_version
    // ========================================================

    const {
      data: acknowledgement,
      error: acknowledgementError,
    } = await supabaseAdmin
      .from("invoice_document_acknowledgements")
      .select(
        `
          id,
          invoice_id,
          user_id,
          document_path,
          document_sha256,
          acknowledgement_text_version,
          accepted_at
        `,
      )
      .eq("invoice_id", invoice.id)
      .eq("user_id", user.id)
      .eq("document_path", documentPath)
      .eq("document_sha256", documentSha256)
      .eq(
        "acknowledgement_text_version",
        INVOICE_DOCUMENT_ACKNOWLEDGEMENT_VERSION,
      )
      .order("accepted_at", {
        ascending: false,
      })
      .limit(1)
      .maybeSingle();

    if (acknowledgementError) {
      console.error(
        "[create-checkout-session] Error comprobando aceptación:",
        acknowledgementError,
      );

      return jsonResponse(
        {
          error:
            "No se ha podido verificar la aceptación del documento de la factura.",
          code:
            acknowledgementError.code ??
            "ACKNOWLEDGEMENT_QUERY_ERROR",
        },
        500,
        corsHeaders,
      );
    }

    if (!acknowledgement) {
      return jsonResponse(
        {
          error:
            "Debes abrir y leer el documento PDF de la factura y aceptar la declaración correspondiente antes de realizar el pago.",
          code:
            "INVOICE_DOCUMENT_ACKNOWLEDGEMENT_REQUIRED",
        },
        409,
        corsHeaders,
      );
    }

    // ========================================================
    // 19. COMPROBACIÓN EXPLÍCITA DE INTEGRIDAD
    // ========================================================

    if (
      String(
        acknowledgement.document_sha256 ?? "",
      )
        .trim()
        .toLowerCase() !== documentSha256
    ) {
      console.error(
        "[create-checkout-session] Inconsistencia de hash:",
        {
          invoiceId: invoice.id,
          userId: user.id,
        },
      );

      return jsonResponse(
        {
          error:
            "La aceptación registrada no corresponde al documento actual de la factura.",
          code:
            "INVOICE_DOCUMENT_HASH_MISMATCH",
        },
        409,
        corsHeaders,
      );
    }

    // ========================================================
    // 20. IMPORTE REAL
    // ========================================================
    //
    // El importe siempre procede de la BD.
    // Nunca del frontend.
    // ========================================================

    const amountInEuros = Number(
      invoice.importe_a_pagar,
    );

    if (
      !Number.isFinite(amountInEuros) ||
      amountInEuros <= 0
    ) {
      console.error(
        "[create-checkout-session] Importe inválido:",
        invoice.importe_a_pagar,
      );

      return jsonResponse(
        {
          error:
            "El importe de la factura no es válido",
        },
        400,
        corsHeaders,
      );
    }

    // ========================================================
    // 21. EUROS → CÉNTIMOS
    // ========================================================

    const amountInCents = Math.round(
      amountInEuros * 100,
    );

    if (amountInCents <= 0) {
      return jsonResponse(
        {
          error:
            "El importe calculado para Stripe no es válido",
        },
        400,
        corsHeaders,
      );
    }

    // ========================================================
    // 22. APP URL
    // ========================================================

    const rawAppUrl =
      Deno.env.get("APP_URL");

    if (!rawAppUrl) {
      return jsonResponse(
        {
          error:
            "Configuración de checkout no disponible.",
        },
        503,
        corsHeaders,
      );
    }

    const appUrl = rawAppUrl
      .trim()
      .replace(/\/+$/, "");

    if (!appUrl) {
      return jsonResponse(
        {
          error:
            "Configuración de checkout no disponible.",
        },
        503,
        corsHeaders,
      );
    }

    // ========================================================
    // 23. PREPARAR INFORMACIÓN PARA STRIPE
    // ========================================================

    const invoiceNumber =
      String(
        invoice.numero_factura ?? "",
      ).trim() ||
      invoice.id;

    const rawTitle = getInvoiceTitle(
      invoice.descripcion,
      invoiceNumber,
    );

    const rawDescription =
      formatInvoiceDescriptionForStripe(
        invoice.descripcion,
        invoiceNumber,
        invoice.fecha_vencimiento,
      );

    const stripeProductName =
      truncateForStripe(
        rawTitle,
        250,
      );

    const stripeDescription =
      truncateForStripe(
        rawDescription,
        500,
      );

    // ========================================================
    // 24. CREAR CHECKOUT SESSION
    // ========================================================

    let session: Stripe.Checkout.Session;

    try {
      session =
        await stripe.checkout.sessions.create({
          mode: "payment",

          line_items: [
            {
              price_data: {
                currency: "eur",

                product_data: {
                  name: stripeProductName,
                  description:
                    stripeDescription,
                },

                unit_amount:
                  amountInCents,
              },

              quantity: 1,
            },
          ],

          metadata: {
            invoice_id: invoice.id,
            company_id:
              invoice.company_id || "",
            user_id: invoice.user_id,
          },

          payment_intent_data: {
            metadata: {
              invoice_id: invoice.id,
              company_id:
                invoice.company_id || "",
              user_id: invoice.user_id,
            },
          },

          success_url:
            `${appUrl}/area-cliente/facturacion?payment=success&invoice_id=${invoice.id}`,

          cancel_url:
            `${appUrl}/area-cliente/facturacion?payment=cancelled&invoice_id=${invoice.id}`,

          customer_email:
            user.email || undefined,
        });
    } catch (stripeError) {
      console.error(
        "[create-checkout-session] ERROR DE STRIPE:",
        stripeError,
      );

      return jsonResponse(
        {
          error:
            stripeError instanceof Error
              ? stripeError.message
              : "Stripe ha rechazado la creación del Checkout",
          code:
            "STRIPE_CHECKOUT_CREATION_ERROR",
        },
        500,
        corsHeaders,
      );
    }

    // ========================================================
    // 25. COMPROBAR URL
    // ========================================================

    if (!session.url) {
      console.error(
        "[create-checkout-session] Stripe no ha devuelto URL:",
        {
          sessionId: session.id,
          status: session.status,
        },
      );

      return jsonResponse(
        {
          error:
            "Stripe no ha devuelto una URL de Checkout",
          code:
            "STRIPE_CHECKOUT_URL_MISSING",
        },
        500,
        corsHeaders,
      );
    }

    console.log(
      "[create-checkout-session] Checkout creado correctamente:",
      {
        sessionId: session.id,
        invoiceId: invoice.id,
        amountInCents,
      },
    );

    // ========================================================
    // 26. RESPUESTA
    // ========================================================

    return jsonResponse(
      {
        success: true,
        checkout_url: session.url,
      },
      200,
      corsHeaders,
    );
  } catch (error) {
    console.error(
      "[create-checkout-session] ERROR INTERNO:",
      error,
    );

    return jsonResponse(
      {
        error:
          error instanceof Error
            ? error.message
            : "Error interno al crear el pago",
        code:
          "CREATE_CHECKOUT_SESSION_ERROR",
      },
      500,
      corsHeaders,
    );
  }
});
