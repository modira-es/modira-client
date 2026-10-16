import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * ============================================================
 * MODIRA — PREPARE QUOTATION DOCUMENT HASH
 * ============================================================
 *
 * Esta Edge Function prepara el PDF de un presupuesto para
 * su posterior aceptación por parte del cliente.
 *
 * Flujo:
 *
 *   Worker autenticado
 *        ↓
 *   Edge Function
 *        ↓
 *   obtiene el presupuesto
 *        ↓
 *   valida document_path
 *        ↓
 *   descarga el PDF REAL desde Storage
 *        ↓
 *   valida que sea un PDF
 *        ↓
 *   calcula SHA-256
 *        ↓
 *   RPC set_quotation_document_hash()
 *        ↓
 *   quotations.document_sha256
 *
 * IMPORTANTE:
 *
 * - El hash NUNCA viene del frontend.
 * - El archivo utilizado para calcular el hash es el PDF
 *   real almacenado en Storage.
 * - La RPC SQL vuelve a validar permisos y coherencia.
 * - Solo un worker activo puede preparar el documento.
 * - Solo se preparan presupuestos Pendientes.
 *
 * ============================================================
 */

const SUPABASE_URL =
  Deno.env.get("SUPABASE_URL") ?? "";

const SUPABASE_ANON_KEY =
  Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const ALLOWED_ORIGINS_ENV =
  Deno.env.get("MODIRA_ALLOWED_ORIGINS") ?? "";

const BUCKET_NAME =
  "quotations";

const MAX_DOCUMENT_SIZE =
  10 * 1024 * 1024;


/**
 * ============================================================
 * CORS
 * ============================================================
 */

function getAllowedOrigins(): string[] {
  return ALLOWED_ORIGINS_ENV
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
}


function getCorsHeaders(
  req: Request
): Headers {

  const origin =
    req.headers.get("origin");

  const allowedOrigins =
    getAllowedOrigins();

  const headers =
    new Headers();

  if (
    origin &&
    allowedOrigins.includes(origin)
  ) {
    headers.set(
      "Access-Control-Allow-Origin",
      origin
    );
  }

  headers.set(
    "Access-Control-Allow-Headers",
    "authorization, x-client-info, apikey, content-type"
  );

  headers.set(
    "Access-Control-Allow-Methods",
    "POST, OPTIONS"
  );

  headers.set(
    "Access-Control-Max-Age",
    "86400"
  );

  headers.set(
    "Vary",
    "Origin"
  );

  return headers;
}


/**
 * ============================================================
 * JSON RESPONSE
 * ============================================================
 */

function jsonResponse(
  body: unknown,
  status: number,
  corsHeaders: Headers
): Response {

  const headers =
    new Headers(corsHeaders);

  headers.set(
    "Content-Type",
    "application/json; charset=utf-8"
  );

  return new Response(
    JSON.stringify(body),
    {
      status,
      headers,
    }
  );
}


/**
 * ============================================================
 * SHA-256
 * ============================================================
 */

async function calculateSha256(
  data: ArrayBuffer
): Promise<string> {

  const digest =
    await crypto.subtle.digest(
      "SHA-256",
      data
    );

  return Array.from(
    new Uint8Array(digest)
  )
    .map((byte) =>
      byte
        .toString(16)
        .padStart(2, "0")
    )
    .join("");
}


/**
 * ============================================================
 * UUID
 * ============================================================
 */

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;


/**
 * ============================================================
 * MAIN
 * ============================================================
 */

Deno.serve(
  async (req: Request) => {

    const corsHeaders =
      getCorsHeaders(req);


    /**
     * --------------------------------------------------------
     * 1. PREFLIGHT
     * --------------------------------------------------------
     */

    if (req.method === "OPTIONS") {

      return new Response(
        null,
        {
          status: 204,
          headers: corsHeaders,
        }
      );
    }


    /**
     * --------------------------------------------------------
     * 2. SOLO POST
     * --------------------------------------------------------
     */

    if (req.method !== "POST") {

      return jsonResponse(
        {
          error:
            "Método no permitido",

          code:
            "METHOD_NOT_ALLOWED",
        },
        405,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 3. VARIABLES DE ENTORNO
     * --------------------------------------------------------
     */

    if (
      !SUPABASE_URL ||
      !SUPABASE_ANON_KEY ||
      !SUPABASE_SERVICE_ROLE_KEY
    ) {

      console.error(
        "Faltan variables de entorno de Supabase"
      );

      return jsonResponse(
        {
          error:
            "Configuración interna incompleta del servidor",

          code:
            "SERVER_CONFIGURATION_ERROR",
        },
        500,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 4. AUTORIZACIÓN
     * --------------------------------------------------------
     */

    const authorization =
      req.headers.get(
        "Authorization"
      );

    if (!authorization) {

      return jsonResponse(
        {
          error:
            "No autenticado",

          code:
            "AUTH_REQUIRED",
        },
        401,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 5. CLIENTE CON JWT DEL WORKER
     * --------------------------------------------------------
     *
     * Este cliente mantiene el JWT del usuario.
     *
     * Se utiliza para todas las RPC que dependen de:
     *
     *     auth.uid()
     *
     * Esto es importante.
     *
     * No debemos utilizar service_role para las RPC que
     * necesitan conocer la identidad real del worker.
     *
     * --------------------------------------------------------
     */

    const supabaseUser =
      createClient(
        SUPABASE_URL,
        SUPABASE_ANON_KEY,
        {
          global: {
            headers: {
              Authorization:
                authorization,
            },
          },

          auth: {
            persistSession:
              false,

            autoRefreshToken:
              false,

            detectSessionInUrl:
              false,
          },
        }
      );


    /**
     * --------------------------------------------------------
     * 6. VALIDAR SESIÓN
     * --------------------------------------------------------
     */

    const {
      data: {
        user,
      },
      error: userError,
    } =
      await supabaseUser.auth.getUser();


    if (
      userError ||
      !user
    ) {

      console.error(
        "Error obteniendo usuario:",
        userError
      );

      return jsonResponse(
        {
          error:
            "Sesión no válida o expirada",

          code:
            "INVALID_AUTH",
        },
        401,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 7. PARSEAR BODY
     * --------------------------------------------------------
     */

    let body: unknown;

    try {

      body =
        await req.json();

    } catch (error) {

      console.error(
        "Error parseando JSON:",
        error
      );

      return jsonResponse(
        {
          error:
            "El cuerpo de la petición no es JSON válido",

          code:
            "INVALID_JSON",
        },
        400,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 8. VALIDAR BODY
     * --------------------------------------------------------
     */

    if (
      typeof body !== "object" ||
      body === null ||
      !("quotationId" in body)
    ) {

      return jsonResponse(
        {
          error:
            "quotationId es obligatorio",

          code:
            "QUOTATION_ID_REQUIRED",
        },
        400,
        corsHeaders
      );
    }


    const quotationId =
      (
        body as {
          quotationId?: unknown;
        }
      ).quotationId;


    if (
      typeof quotationId !== "string" ||
      quotationId.trim() === ""
    ) {

      return jsonResponse(
        {
          error:
            "quotationId no es válido",

          code:
            "INVALID_QUOTATION_ID",
        },
        400,
        corsHeaders
      );
    }


    const normalizedQuotationId =
      quotationId.trim();


    /**
     * --------------------------------------------------------
     * 9. VALIDAR UUID
     * --------------------------------------------------------
     */

    if (
      !UUID_REGEX.test(
        normalizedQuotationId
      )
    ) {

      return jsonResponse(
        {
          error:
            "quotationId no tiene formato UUID válido",

          code:
            "INVALID_QUOTATION_ID",
        },
        400,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 10. COMPROBAR WORKER
     * --------------------------------------------------------
     *
     * current_user_is_worker() utiliza auth.uid().
     *
     * Por eso se ejecuta mediante supabaseUser, no mediante
     * service_role.
     *
     * --------------------------------------------------------
     */

    const {
      data: isWorker,
      error: workerCheckError,
    } =
      await supabaseUser.rpc(
        "current_user_is_worker"
      );


    if (workerCheckError) {

      console.error(
        "Error comprobando worker:",
        workerCheckError
      );

      return jsonResponse(
        {
          error:
            "No se han podido verificar los permisos del usuario",

          code:
            "WORKER_CHECK_FAILED",
        },
        500,
        corsHeaders
      );
    }


    if (isWorker !== true) {

      return jsonResponse(
        {
          error:
            "Acceso denegado: solo los trabajadores activos pueden preparar el hash del PDF",

          code:
            "WORKER_REQUIRED",
        },
        403,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 11. COMPROBAR PERMISO RBAC
     * --------------------------------------------------------
     *
     * Preparar/registrar el hash modifica el documento del
     * presupuesto, por lo que requiere quotations.update.
     *
     * Se comprueba mediante el cliente autenticado para que
     * current_worker_has_permission() evalúe el JWT real del worker.
     *
     * --------------------------------------------------------
     */

    const {
      data: hasQuotationUpdatePermission,
      error: quotationPermissionError,
    } = await supabaseUser.rpc(
      "current_worker_has_permission",
      {
        p_permission_code: "quotations.update",
      }
    );

    if (quotationPermissionError) {

      console.error(
        "Error comprobando permiso quotations.update:",
        quotationPermissionError
      );

      return jsonResponse(
        {
          error:
            "No se ha podido verificar el permiso del trabajador",

          code:
            "PERMISSION_CHECK_FAILED",
        },
        500,
        corsHeaders
      );
    }

    if (hasQuotationUpdatePermission !== true) {

      return jsonResponse(
        {
          error:
            "Acceso denegado: se requiere el permiso quotations.update",

          code:
            "QUOTATION_UPDATE_PERMISSION_REQUIRED",
        },
        403,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 12. CLIENTE SERVICE ROLE
     * --------------------------------------------------------
     *
     * Se utiliza únicamente para:
     *
     * - consultar quotations;
     * - descargar el PDF privado de Storage.
     *
     * Nunca se utiliza para sustituir la identidad del worker
     * en las RPC protegidas.
     *
     * --------------------------------------------------------
     */

    const supabaseAdmin =
      createClient(
        SUPABASE_URL,
        SUPABASE_SERVICE_ROLE_KEY,
        {
          auth: {
            persistSession:
              false,

            autoRefreshToken:
              false,

            detectSessionInUrl:
              false,
          },
        }
      );


    /**
     * --------------------------------------------------------
     * 13. OBTENER PRESUPUESTO
     * --------------------------------------------------------
     */

    const {
      data: quotation,
      error: quotationError,
    } =
      await supabaseAdmin
        .from("quotations")
        .select(
          `
            id,
            company_id,
            numero_presupuesto,
            estado,
            document_path,
            document_sha256
          `
        )
        .eq(
          "id",
          normalizedQuotationId
        )
        .maybeSingle();


    if (quotationError) {

      console.error(
        "Error obteniendo presupuesto:",
        quotationError
      );

      return jsonResponse(
        {
          error:
            "No se ha podido obtener el presupuesto",

          code:
            "QUOTATION_LOOKUP_FAILED",
        },
        500,
        corsHeaders
      );
    }


    if (!quotation) {

      return jsonResponse(
        {
          error:
            "Presupuesto no encontrado",

          code:
            "QUOTATION_NOT_FOUND",
        },
        404,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 14. SOLO PRESUPUESTOS PENDIENTES
     * --------------------------------------------------------
     *
     * El flujo de aceptación documental solo aplica a
     * presupuestos Pendientes.
     *
     * --------------------------------------------------------
     */

    if (
      typeof quotation.estado !== "string" ||
      quotation.estado.trim().toLowerCase() !== "pendiente"
    ) {

      return jsonResponse(
        {
          error:
            "Solo se puede preparar para aceptación un presupuesto pendiente",

          code:
            "QUOTATION_NOT_PENDING",
        },
        409,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 15. VALIDAR DOCUMENT_PATH
     * --------------------------------------------------------
     */

    if (
      !quotation.document_path ||
      quotation.document_path.trim() === ""
    ) {

      return jsonResponse(
        {
          error:
            "El presupuesto no tiene un PDF asociado",

          code:
            "DOCUMENT_NOT_ATTACHED",
        },
        409,
        corsHeaders
      );
    }


    const documentPath =
      quotation.document_path.trim();


    /**
     * --------------------------------------------------------
     * 16. VALIDAR RUTA ESPERADA
     * --------------------------------------------------------
     *
     * Formato establecido por attach_quotation_document():
     *
     *     company_id/numero_presupuesto.pdf
     *
     * --------------------------------------------------------
     */

    const expectedDocumentPath =
      `${quotation.company_id}/${quotation.numero_presupuesto}.pdf`;


    if (
      documentPath !==
      expectedDocumentPath
    ) {

      console.error(
        "Ruta de documento inesperada:",
        {
          quotationId:
            quotation.id,

          documentPath,

          expectedDocumentPath,
        }
      );

      return jsonResponse(
        {
          error:
            "La ruta del PDF no coincide con la ruta esperada del presupuesto",

          code:
            "INVALID_DOCUMENT_PATH",
        },
        409,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 17. DESCARGAR PDF REAL
     * --------------------------------------------------------
     */

    const {
      data: pdfData,
      error: downloadError,
    } =
      await supabaseAdmin.storage
        .from(BUCKET_NAME)
        .download(
          documentPath
        );


    if (downloadError) {

      console.error(
        "Error descargando PDF:",
        {
          quotationId:
            quotation.id,

          documentPath,

          error:
            downloadError,
        }
      );

      return jsonResponse(
        {
          error:
            "No se ha podido descargar el PDF del presupuesto desde Storage",

          code:
            "DOCUMENT_DOWNLOAD_FAILED",
        },
        500,
        corsHeaders
      );
    }


    if (!pdfData) {

      return jsonResponse(
        {
          error:
            "Storage no ha devuelto el PDF",

          code:
            "DOCUMENT_EMPTY",
        },
        500,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 18. VALIDAR TAMAÑO
     * --------------------------------------------------------
     */

    if (
      pdfData.size <= 0
    ) {

      return jsonResponse(
        {
          error:
            "El PDF del presupuesto está vacío",

          code:
            "DOCUMENT_EMPTY",
        },
        422,
        corsHeaders
      );
    }


    if (
      pdfData.size >
      MAX_DOCUMENT_SIZE
    ) {

      return jsonResponse(
        {
          error:
            "El PDF del presupuesto supera el tamaño máximo permitido",

          code:
            "DOCUMENT_TOO_LARGE",
        },
        413,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 19. VALIDAR FIRMA PDF
     * --------------------------------------------------------
     *
     * Un archivo PDF válido comienza con:
     *
     *     %PDF-
     *
     * No confiamos únicamente en la extensión del archivo.
     *
     * --------------------------------------------------------
     */

    const firstBytes =
      new Uint8Array(
        await pdfData
          .slice(
            0,
            5
          )
          .arrayBuffer()
      );


    const pdfMagic =
      new TextDecoder().decode(
        firstBytes
      );


    if (
      pdfMagic !==
      "%PDF-"
    ) {

      console.error(
        "El objeto no tiene firma PDF válida:",
        {
          quotationId:
            quotation.id,

          documentPath,

          pdfMagic,
        }
      );

      return jsonResponse(
        {
          error:
            "El archivo asociado al presupuesto no es un PDF válido",

          code:
            "INVALID_PDF",
        },
        422,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 20. OBTENER BYTES COMPLETOS
     * --------------------------------------------------------
     */

    const pdfArrayBuffer =
      await pdfData.arrayBuffer();


    /**
     * --------------------------------------------------------
     * 21. CALCULAR SHA-256
     * --------------------------------------------------------
     */

    const documentSha256 =
      await calculateSha256(
        pdfArrayBuffer
      );


    /**
     * --------------------------------------------------------
     * 22. VALIDAR HASH
     * --------------------------------------------------------
     */

    if (
      !/^[0-9a-f]{64}$/.test(
        documentSha256
      )
    ) {

      console.error(
        "SHA-256 generado con formato inesperado"
      );

      return jsonResponse(
        {
          error:
            "No se ha podido generar un SHA-256 válido",

          code:
            "HASH_GENERATION_FAILED",
        },
        500,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 23. EVITAR ESCRITURA INNECESARIA
     * --------------------------------------------------------
     *
     * Si el documento ya tiene exactamente el mismo hash,
     * no necesitamos modificar la fila.
     *
     * Esto hace la operación idempotente.
     *
     * --------------------------------------------------------
     */

    if (
      typeof quotation.document_sha256 === "string" &&
      quotation.document_sha256.trim().toLowerCase() ===
        documentSha256
    ) {

      return jsonResponse(
        {
          success:
            true,

          quotationId:
            quotation.id,

          documentPath,

          documentSha256,

          documentSize:
            pdfData.size,

          alreadyPrepared:
            true,

          message:
            "El hash SHA-256 del PDF ya estaba correctamente registrado",
        },
        200,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 24. GUARDAR HASH MEDIANTE RPC
     * --------------------------------------------------------
     *
     * IMPORTANTE:
     *
     * Esta llamada utiliza supabaseUser para conservar:
     *
     *     auth.uid()
     *
     * La RPC set_quotation_document_hash() es la autoridad
     * final para validar:
     *
     * - worker;
     * - presupuesto;
     * - ruta;
     * - Storage;
     * - hash;
     * - coherencia del documento.
     *
     * --------------------------------------------------------
     */

    const {
      data: updatedQuotation,
      error: hashRpcError,
    } =
      await supabaseUser.rpc(
        "set_quotation_document_hash",
        {
          p_quotation_id:
            normalizedQuotationId,

          p_document_path:
            documentPath,

          p_document_sha256:
            documentSha256,
        }
      );


    if (hashRpcError) {

      console.error(
        "Error guardando hash del PDF:",
        {
          quotationId:
            quotation.id,

          documentPath,

          hashRpcError,
        }
      );

      return jsonResponse(
        {
          error:
            "No se ha podido guardar el hash del PDF del presupuesto",

          code:
            "HASH_SAVE_FAILED",

          details:
            hashRpcError.message,
        },
        500,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 25. COMPROBAR RESPUESTA RPC
     * --------------------------------------------------------
     */

    if (
      !updatedQuotation
    ) {

      console.error(
        "La RPC no devolvió el presupuesto actualizado"
      );

      return jsonResponse(
        {
          error:
            "El hash se procesó pero no se recibió confirmación de la base de datos",

          code:
            "HASH_SAVE_UNCONFIRMED",
        },
        500,
        corsHeaders
      );
    }


    /**
     * --------------------------------------------------------
     * 26. RESPUESTA FINAL
     * --------------------------------------------------------
     */

    return jsonResponse(
      {
        success:
          true,

        quotationId:
          quotation.id,

        documentPath,

        documentSha256,

        documentSize:
          pdfData.size,

        alreadyPrepared:
          false,

        message:
          "Hash SHA-256 del PDF del presupuesto calculado y registrado correctamente",
      },
      200,
      corsHeaders
    );
  }
);