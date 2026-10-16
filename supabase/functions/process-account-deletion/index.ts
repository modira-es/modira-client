import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get(
  "SUPABASE_SERVICE_ROLE_KEY",
);

if (
  !SUPABASE_URL ||
  !SUPABASE_ANON_KEY ||
  !SUPABASE_SERVICE_ROLE_KEY
) {
  throw new Error("Supabase environment variables are missing");
}

/*
 * ============================================================
 * CLIENTE DE AUTENTICACIÓN
 * ============================================================
 *
 * Se utiliza exclusivamente para validar el JWT enviado
 * por el trabajador.
 *
 * Nunca utilizamos service_role para confiar en la identidad
 * enviada por el navegador.
 */

const authClient = createClient(
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  },
);

/*
 * ============================================================
 * CLIENTE ADMINISTRATIVO
 * ============================================================
 *
 * SOLO BACKEND.
 *
 * Nunca se expone SUPABASE_SERVICE_ROLE_KEY al frontend.
 */

const adminClient = createClient(
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  },
);

/*
 * ============================================================
 * CORS
 * ============================================================
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

/*
 * ============================================================
 * RESPUESTA JSON
 * ============================================================
 */

function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
) {
  return new Response(
    JSON.stringify(body),
    {
      status,
      headers: corsHeaders,
    },
  );
}

/*
 * ============================================================
 * UUID
 * ============================================================
 */

function isValidUuid(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  );
}

/*
 * ============================================================
 * EDGE FUNCTION
 * ============================================================
 */

Deno.serve(async (req) => {
  /*
   * ----------------------------------------------------------
   * 1. CORS
   * ----------------------------------------------------------
   */

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  /*
   * ----------------------------------------------------------
   * 2. SOLO POST
   * ----------------------------------------------------------
   */

  if (req.method !== "POST") {
    return jsonResponse(
      {
        error: "Method not allowed",
      },
      405,
    );
  }

  try {
    /*
     * --------------------------------------------------------
     * 3. AUTENTICACIÓN
     * --------------------------------------------------------
     */

    const authorization =
      req.headers.get("Authorization");

    if (!authorization?.startsWith("Bearer ")) {
      return jsonResponse(
        {
          error: "Authentication required",
        },
        401,
      );
    }

    const accessToken =
      authorization.substring("Bearer ".length).trim();

    if (!accessToken) {
      return jsonResponse(
        {
          error: "Authentication required",
        },
        401,
      );
    }

    /*
     * --------------------------------------------------------
     * 4. VALIDAR JWT
     * --------------------------------------------------------
     */

    const {
      data: {
        user,
      },
      error: userError,
    } = await authClient.auth.getUser(accessToken);

    if (userError || !user) {
      return jsonResponse(
        {
          error: "Invalid authentication",
        },
        401,
      );
    }

    const workerId = user.id;

    /*
     * --------------------------------------------------------
     * 5. CLIENTE AUTENTICADO CON EL JWT DEL WORKER
     * --------------------------------------------------------
     *
     * IMPORTANTE:
     *
     * El adminClient utiliza service_role y, por tanto,
     * no representa al trabajador.
     *
     * Para comprobar current_worker_has_permission()
     * necesitamos conservar el JWT original.
     */

    const workerClient = createClient(
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
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

    /*
     * --------------------------------------------------------
     * 6. COMPROBAR WORKER ACTIVO
     * --------------------------------------------------------
     */

    const {
      data: worker,
      error: workerError,
    } = await adminClient
      .from("workers")
      .select(`
        auth_user_id,
        is_active
      `)
      .eq("auth_user_id", workerId)
      .eq("is_active", true)
      .maybeSingle();

    if (workerError) {
      console.error(
        "Worker lookup failed:",
        workerError,
      );

      return jsonResponse(
        {
          error: "Unable to verify worker",
        },
        500,
      );
    }

    if (!worker) {
      return jsonResponse(
        {
          error: "Access denied",
        },
        403,
      );
    }

    /*
     * --------------------------------------------------------
     * 7. COMPROBAR PROFILE ACTIVO
     * --------------------------------------------------------
     */

    const {
      data: workerProfile,
      error: workerProfileError,
    } = await adminClient
      .from("profiles")
      .select(`
        id,
        status
      `)
      .eq("id", workerId)
      .maybeSingle();

    if (
      workerProfileError ||
      !workerProfile ||
      workerProfile.status !== "active"
    ) {
      return jsonResponse(
        {
          error: "Access denied",
        },
        403,
      );
    }

    /*
     * --------------------------------------------------------
     * 8. COMPROBAR PERMISO GRANULAR
     * --------------------------------------------------------
     *
     * Este es el cambio principal respecto a la función antigua.
     *
     * Ser worker NO es suficiente.
     *
     * Solo un worker con:
     *
     *     system.data.delete
     *
     * puede ejecutar la eliminación de una cuenta.
     */

    const {
      data: hasDeletePermission,
      error: permissionError,
    } = await workerClient.rpc(
      "current_worker_has_permission",
      {
        p_permission_code: "system.data.delete",
      },
    );

    if (permissionError) {
      console.error(
        "Permission check failed:",
        permissionError,
      );

      return jsonResponse(
        {
          error: "Unable to verify permissions",
        },
        500,
      );
    }

    if (hasDeletePermission !== true) {
      return jsonResponse(
        {
          error: "Access denied",
        },
        403,
      );
    }

    /*
     * --------------------------------------------------------
     * 9. LEER REQUEST_ID
     * --------------------------------------------------------
     */

    let body: unknown;

    try {
      body = await req.json();
    } catch {
      return jsonResponse(
        {
          error: "Invalid JSON body",
        },
        400,
      );
    }

    if (
      typeof body !== "object" ||
      body === null ||
      !("request_id" in body)
    ) {
      return jsonResponse(
        {
          error: "request_id is required",
        },
        400,
      );
    }

    const requestId = (
      body as {
        request_id?: unknown;
      }
    ).request_id;

    if (!isValidUuid(requestId)) {
      return jsonResponse(
        {
          error: "Invalid request_id",
        },
        400,
      );
    }

    /*
     * --------------------------------------------------------
     * 10. OBTENER SOLICITUD
     * --------------------------------------------------------
     */

    const {
      data: deletionRequest,
      error: deletionRequestError,
    } = await adminClient
      .from("account_deletion_requests")
      .select(`
        id,
        user_id,
        status,
        requested_at,
        reviewed_at,
        reviewed_by
      `)
      .eq("id", requestId)
      .maybeSingle();

    if (deletionRequestError) {
      console.error(
        "Deletion request lookup failed:",
        deletionRequestError,
      );

      return jsonResponse(
        {
          error: "Unable to read deletion request",
        },
        500,
      );
    }

    if (!deletionRequest) {
      return jsonResponse(
        {
          error: "Deletion request not found",
        },
        404,
      );
    }

    /*
     * --------------------------------------------------------
     * 11. SOLO PROCESAR REQUEST APROBADA
     * --------------------------------------------------------
     */

    if (deletionRequest.status !== "approved") {
      return jsonResponse(
        {
          error:
            "The deletion request is not approved",
          status: deletionRequest.status,
        },
        409,
      );
    }

    /*
     * --------------------------------------------------------
     * 12. COMPROBAR USUARIO OBJETIVO
     * --------------------------------------------------------
     */

    if (!deletionRequest.user_id) {
      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "failed",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Deletion request has no target user",
        },
        409,
      );
    }

    const targetUserId =
      deletionRequest.user_id;

    /*
     * --------------------------------------------------------
     * 13. COMPROBAR QUE EL TARGET SIGUE SIENDO CLIENTE
     * --------------------------------------------------------
     */

    const {
      data: targetProfile,
      error: targetProfileError,
    } = await adminClient
      .from("profiles")
      .select(`
        id,
        rol,
        status
      `)
      .eq("id", targetUserId)
      .maybeSingle();

    if (targetProfileError) {
      console.error(
        "Target profile lookup failed:",
        targetProfileError,
      );

      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "failed",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error: "Unable to verify target account",
        },
        500,
      );
    }

    /*
     * Si existe profile, obligatoriamente debe ser cliente.
     */

    if (
      targetProfile &&
      targetProfile.rol !== "user"
    ) {
      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "blocked",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Only client accounts can be deleted",
          status: "blocked",
        },
        409,
      );
    }

    /*
     * --------------------------------------------------------
     * 14. COMPROBAR QUE NO SEA WORKER
     * --------------------------------------------------------
     */

    const {
      data: targetWorker,
      error: targetWorkerError,
    } = await adminClient
      .from("workers")
      .select(`
        auth_user_id
      `)
      .eq("auth_user_id", targetUserId)
      .maybeSingle();

    if (targetWorkerError) {
      console.error(
        "Target worker lookup failed:",
        targetWorkerError,
      );

      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "failed",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Unable to verify target worker status",
        },
        500,
      );
    }

    if (targetWorker) {
      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "blocked",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Worker accounts cannot be deleted through this flow",
          status: "blocked",
        },
        409,
      );
    }

    /*
     * --------------------------------------------------------
     * 15. COMPROBACIÓN FINAL DE PROYECTOS
     * --------------------------------------------------------
     *
     * BLOQUEAN:
     * - Activo
     * - Pausado
     * - Completado
     *
     * NO BLOQUEAN:
     * - Pendiente
     * - Entregado
     */

    const {
      data: blockingProjects,
      error: projectsError,
    } = await adminClient
      .from("projects")
      .select(`
        id,
        nombre,
        estado
      `)
      .eq("user_id", targetUserId)
      .in("estado", [
        "Activo",
        "Pausado",
        "Completado",
      ])
      .limit(1);

    if (projectsError) {
      console.error(
        "Project check failed:",
        projectsError,
      );

      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "failed",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Unable to verify project status",
        },
        500,
      );
    }

    if (
      blockingProjects &&
      blockingProjects.length > 0
    ) {
      const project =
        blockingProjects[0];

      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "blocked",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Account deletion blocked by an active project",
          status: "blocked",
          reason: "project",
          project_id: project.id,
          project_status: project.estado,
        },
        409,
      );
    }

    /*
     * --------------------------------------------------------
     * 16. COMPROBACIÓN FINAL DE FACTURAS
     * --------------------------------------------------------
     *
     * BLOQUEAN:
     * - pendiente
     * - vencida
     *
     * NO BLOQUEAN:
     * - pagada
     * - cancelada
     */

    const {
      data: blockingInvoices,
      error: invoicesError,
    } = await adminClient
      .from("invoices")
      .select(`
        id,
        numero_factura,
        estado
      `)
      .eq("user_id", targetUserId)
      .in("estado", [
        "pendiente",
        "vencida",
      ])
      .limit(1);

    if (invoicesError) {
      console.error(
        "Invoice check failed:",
        invoicesError,
      );

      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "failed",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Unable to verify invoice status",
        },
        500,
      );
    }

    if (
      blockingInvoices &&
      blockingInvoices.length > 0
    ) {
      const invoice =
        blockingInvoices[0];

      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "blocked",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error:
            "Account deletion blocked by an unpaid invoice",
          status: "blocked",
          reason: "invoice",
          invoice_id: invoice.id,
          invoice_status: invoice.estado,
        },
        409,
      );
    }

    /*
     * --------------------------------------------------------
     * 17. ÚLTIMA COMPROBACIÓN DE LA REQUEST
     * --------------------------------------------------------
     *
     * Evitamos ejecutar una request que haya cambiado
     * mientras se realizaban las comprobaciones.
     */

    const {
      data: latestRequest,
      error: latestRequestError,
    } = await adminClient
      .from("account_deletion_requests")
      .select(`
        id,
        user_id,
        status
      `)
      .eq("id", requestId)
      .maybeSingle();

    if (
      latestRequestError ||
      !latestRequest
    ) {
      console.error(
        "Final request verification failed:",
        latestRequestError,
      );

      return jsonResponse(
        {
          error:
            "Unable to perform final deletion verification",
        },
        500,
      );
    }

    if (
      latestRequest.status !== "approved" ||
      latestRequest.user_id !== targetUserId
    ) {
      return jsonResponse(
        {
          error:
            "Deletion request changed before execution",
          status: latestRequest.status,
        },
        409,
      );
    }

    /*
     * --------------------------------------------------------
     * 18. ELIMINAR USUARIO DE SUPABASE AUTH
     * --------------------------------------------------------
     *
     * Esta es la única operación que elimina realmente
     * la cuenta de Auth.
     *
     * Se realiza exclusivamente mediante service_role.
     */

    const {
      error: deleteUserError,
    } = await adminClient.auth.admin.deleteUser(
      targetUserId,
      false,
    );

    if (deleteUserError) {
      console.error(
        "Auth user deletion failed:",
        deleteUserError,
      );

      await adminClient
        .from("account_deletion_requests")
        .update({
          status: "failed",
        })
        .eq("id", requestId);

      return jsonResponse(
        {
          error: "Account deletion failed",
        },
        500,
      );
    }

    /*
     * --------------------------------------------------------
     * 19. MARCAR REQUEST COMO COMPLETADA
     * --------------------------------------------------------
     *
     * account_deletion_requests.user_id tiene ON DELETE SET NULL,
     * por lo que actualizamos mediante request_id.
     */

    const {
      error: completionError,
    } = await adminClient
      .from("account_deletion_requests")
      .update({
        status: "completed",
      })
      .eq("id", requestId);

    /*
     * La cuenta ya ha sido eliminada.
     *
     * No podemos revertir el DELETE de Auth.
     */

    if (completionError) {
      console.error(
        "Account deleted but request could not be marked completed:",
        completionError,
      );

      return jsonResponse(
        {
          success: true,
          status: "completed",
          warning:
            "Account deleted successfully, but the request status could not be updated",
        },
        200,
      );
    }

    /*
     * --------------------------------------------------------
     * 20. RESPUESTA FINAL
     * --------------------------------------------------------
     */

    return jsonResponse(
      {
        success: true,
        status: "completed",
      },
      200,
    );
  } catch (error) {
    console.error(
      "Unexpected account deletion error:",
      error,
    );

    return jsonResponse(
      {
        error:
          "Unexpected account deletion error",
      },
      500,
    );
  }
});