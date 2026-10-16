// MODIRA — Supabase Edge Function: maintenance-stripe
//
// Handles the secure server-side lifecycle of Modira maintenance
// subscriptions through Stripe Billing.
//
// Supported authenticated actions:
//   - create_checkout_session
//   - request_cancellation
//   - request_plan_change
//   - request_maintenance_project_change
//   - approve_maintenance_project_change
//   - reject_maintenance_project_change
//   - cancel_maintenance_project_change
//   - get_subscription_status
//   - resume_billing_after_fiscal_update
//   - reconcile_subscription
// Worker actions:
//   - hash_maintenance_invoice_document
//   - attach_maintenance_custom_proposal_document
//
// Stripe webhook actions are handled on the same endpoint and are
// authenticated with Stripe-Signature rather than a Supabase JWT.
//
// Required Supabase secrets:
//   SUPABASE_URL
//   SUPABASE_ANON_KEY
//   SUPABASE_SERVICE_ROLE_KEY
//   STRIPE_SECRET_KEY
//   MAINTENANCE_STRIPE_WEBHOOK_SECRET
//   MODIRA_APP_URL
// Optional issuer snapshot variables used by the official invoice PDF:
//   MODIRA_INVOICE_ISSUER_LEGAL_NAME
//   MODIRA_INVOICE_ISSUER_TAX_ID
//   MODIRA_INVOICE_ISSUER_ADDRESS
//   MODIRA_INVOICE_ISSUER_POSTAL_CODE
//   MODIRA_INVOICE_ISSUER_CITY
//   MODIRA_INVOICE_ISSUER_PROVINCE
//   MODIRA_INVOICE_ISSUER_COUNTRY
//
// Fixed maintenance plans use the official Stripe Price IDs stored in
// public.maintenance_plans.stripe_price_id.
// Custom maintenance proposals are different: once a proposal is accepted,
// this function creates a dedicated Stripe Product + recurring monthly Price
// for the exact agreed amount and then starts the normal Checkout/subscription
// lifecycle using the existing contract/invoice/payment infrastructure.

import Stripe from "npm:stripe@18.5.0";
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY");
const MAINTENANCE_STRIPE_WEBHOOK_SECRET = Deno.env.get("MAINTENANCE_STRIPE_WEBHOOK_SECRET");
const MODIRA_APP_URL = Deno.env.get("MODIRA_APP_URL");
const MAINTENANCE_TERMS_VERSION = Deno.env.get("MODIRA_MAINTENANCE_TERMS_VERSION") || "v1";
const MAX_CONSECUTIVE_PAYMENT_FAILURES = 3;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !STRIPE_SECRET_KEY) {
  throw new Error("Missing required server environment variables");
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
});

const stripe = new Stripe(STRIPE_SECRET_KEY, {
  maxNetworkRetries: 2,
});

const getCorsHeaders = () => ({
  // CORS no sustituye a la autenticación: las operaciones protegidas
  // siguen exigiendo el Bearer token en requireActiveUser/requireActiveWorker.
  // Se permite cualquier origen para evitar que MODIRA_APP_URL mal configurada
  // bloquee el preflight del navegador.
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Content-Type": "application/json",
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: getCorsHeaders(),
  });

class HttpError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function requireEnv(value: string | undefined, name: string): string {
  if (!value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

function getBearerToken(req: Request): string {
  const header = req.headers.get("Authorization") || "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) throw new HttpError(401, "Falta el token de autenticación");
  return match[1];
}

async function requireActiveUser(req: Request) {
  const token = getBearerToken(req);
  const { data, error } = await supabase.auth.getUser(token);

  if (error || !data.user) {
    throw new HttpError(401, "Sesión no válida");
  }

  const userId = data.user.id;

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("id, company_id, status")
    .eq("id", userId)
    .maybeSingle();

  if (profileError) {
    console.error("[maintenance-stripe] profile lookup failed", profileError);
    throw new HttpError(500, "No se pudo validar el perfil");
  }

  if (!profile || profile.status !== "active") {
    throw new HttpError(403, "La cuenta no está activa");
  }

  if (!profile.company_id) {
    throw new HttpError(403, "La cuenta no está asociada a una empresa");
  }

  return {
    user: data.user,
    profile,
    companyId: profile.company_id as string,
  };
}

async function requireActiveWorker(req: Request) {
  const token = getBearerToken(req);
  const { data, error } = await supabase.auth.getUser(token);

  if (error || !data.user) {
    throw new HttpError(401, "Sesión no válida");
  }

  const { data: worker, error: workerError } = await supabase
    .from("workers")
    .select("id, auth_user_id, is_active")
    .eq("auth_user_id", data.user.id)
    .eq("is_active", true)
    .maybeSingle();

  if (workerError) {
    console.error("[maintenance-stripe] worker lookup failed", workerError);
    throw new HttpError(500, "No se pudo validar el trabajador");
  }

  if (!worker) {
    throw new HttpError(403, "Acceso denegado: se requiere un trabajador activo");
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("id, status")
    .eq("id", data.user.id)
    .maybeSingle();

  if (profileError) {
    console.error("[maintenance-stripe] worker profile lookup failed", profileError);
    throw new HttpError(500, "No se pudo validar el estado del trabajador");
  }

  if (!profile || profile.status !== "active") {
    throw new HttpError(403, "Acceso denegado: el perfil del trabajador no está activo");
  }

  return {
    user: data.user,
    worker,
    profile,
  };
}

async function requireWorkerPermission(
  req: Request,
  permissionCode: string,
) {
  const authenticatedSupabase = getAuthenticatedSupabaseClient(req);

  const { data: allowed, error } = await authenticatedSupabase.rpc(
    "current_worker_has_permission",
    {
      p_permission_code: permissionCode,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] worker permission check failed", {
      permission: permissionCode,
      error,
    });
    throw new HttpError(500, "No se pudo comprobar el permiso del trabajador");
  }

  if (allowed !== true) {
    throw new HttpError(403, `Acceso denegado: se requiere el permiso ${permissionCode}`);
  }
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
}

function companyDisplayName(company: Record<string, unknown>, fallback: string) {
  const candidates = [
    company.nombre,
    company.razon_social,
    company.legal_name,
    company.name,
    company.empresa,
    company.company_name,
  ];

  const name = candidates.find((v) => typeof v === "string" && v.trim());
  return typeof name === "string" ? name.trim() : fallback;
}

function companyTaxId(company: Record<string, unknown>): string | null {
  const candidates = [
    company.cif_vat,
    company.nif,
    company.cif,
    company.tax_id,
    company.identificacion_fiscal,
  ];

  const value = candidates.find((v) => typeof v === "string" && v.trim());
  return typeof value === "string" ? value.trim() : null;
}

function companyFiscalSnapshot(company: Record<string, unknown>) {
  const first = (...keys: string[]) => {
    for (const key of keys) {
      const value = company[key];
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return null;
  };

  return {
    legalName:
      first("legal_name", "razon_social", "legalName") ||
      first("company_name", "nombre", "name", "empresa") ||
      "",
    taxId: companyTaxId(company) || "",
    address: first("address", "direccion", "domicilio", "direccion_fiscal"),
    postalCode: first("postal_code", "codigo_postal", "cp", "codigoPostal"),
    city: first("city", "ciudad", "localidad"),
    province: first("province", "provincia"),
    country: first("country", "pais") || "ES",
  };
}

function missingFiscalFields(company: Record<string, unknown>): string[] {
  const fiscal = companyFiscalSnapshot(company);
  const missing: string[] = [];

  if (!fiscal.legalName) missing.push("razón social");
  if (!fiscal.taxId) missing.push("NIF/CIF/VAT");
  if (!fiscal.address) missing.push("dirección fiscal");
  if (!fiscal.postalCode) missing.push("código postal");
  if (!fiscal.city) missing.push("ciudad");
  if (!fiscal.country) missing.push("país");

  return missing;
}

function assertCurrentFiscalData(company: Record<string, unknown>) {
  const missing = missingFiscalFields(company);
  if (missing.length > 0) {
    throw new HttpError(
      409,
      `La empresa debe tener los datos fiscales actuales completos antes de contratar o cobrar mantenimiento. Falta: ${missing.join(", ")}.`,
    );
  }
}


async function getCompany(companyId: string) {
  const { data, error } = await supabase
    .from("companies")
    .select("*")
    .eq("id", companyId)
    .maybeSingle();

  if (error) {
  console.error("[maintenance-stripe] company lookup failed", {
    message: error.message,
    code: error.code,
    details: error.details,
    hint: error.hint,
  });

  throw new HttpError(
    500,
    `No se pudo cargar la empresa: ${error.message}`,
  );
}

  if (!data) throw new HttpError(404, "Empresa no encontrada");

  const company = asRecord(data);

  if ("is_active" in company && company.is_active !== true) {
    throw new HttpError(403, "La empresa no está activa");
  }

  return company;
}

async function getPlanByCode(planCode: string) {
  if (!planCode || !/^[a-z0-9_-]{2,50}$/.test(planCode)) {
    throw new HttpError(400, "Código de plan no válido");
  }

  const { data, error } = await supabase
    .from("maintenance_plans")
    .select("*")
    .eq("code", planCode)
    .eq("activo", true)
    .maybeSingle();

  if (error) {
    console.error("[maintenance-stripe] plan lookup failed", error);
    throw new HttpError(500, "No se pudo cargar el plan");
  }

  if (!data) throw new HttpError(404, "Plan no encontrado o inactivo");
  return data;
}



async function getProjectForCompany(projectId: string, companyId: string) {
  if (!projectId || !/^[0-9a-f-]{36}$/i.test(projectId)) {
    throw new HttpError(400, "project_id no válido");
  }

  const { data, error } = await supabase
    .from("projects")
    .select("id, company_id, nombre")
    .eq("id", projectId)
    .maybeSingle();

  if (error) {
    console.error("[maintenance-stripe] project lookup failed", error);
    throw new HttpError(500, "No se pudo validar el proyecto");
  }

  if (!data) {
    throw new HttpError(404, "Proyecto no encontrado");
  }

  if (data.company_id !== companyId) {
    throw new HttpError(403, "El proyecto seleccionado no pertenece a tu empresa");
  }

  return data;
}

async function getActiveContractForProject(projectId: string) {
  const { data, error } = await supabase
    .from("maintenance_contract_projects")
    .select(`
      maintenance_contract_id,
      maintenance_contracts!inner (
        id,
        company_id,
        estado,
        stripe_subscription_id
      )
    `)
    .eq("project_id", projectId)
    .in("maintenance_contracts.estado", ["activo", "pausado"])
    .order("maintenance_contract_id", { ascending: false })
    .limit(1);

  if (error) {
    console.error("[maintenance-stripe] project contract lookup failed", error);
    throw new HttpError(500, "No se pudo comprobar el contrato del proyecto");
  }

  const row = data?.[0] as any;
  return row?.maintenance_contracts || null;
}

async function assertProjectAvailableForMaintenance(projectId: string, companyId: string) {
  const project = await getProjectForCompany(projectId, companyId);
  const existingContract = await getActiveContractForProject(projectId);

  if (existingContract) {
    throw new HttpError(
      409,
      "El proyecto seleccionado ya tiene un contrato de mantenimiento activo o pausado."
    );
  }

  return project;
}

async function consumeMaintenanceContractRateLimit(companyId: string) {
  const { error } = await supabase.rpc(
    "consume_maintenance_contract_checkout_rate_limit",
    {
      p_company_id: companyId,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] maintenance contract rate limit failed", error);
    throw new HttpError(
      429,
      "Has alcanzado el límite de contrataciones de mantenimiento permitido para las últimas 24 horas. Vuelve a intentarlo más tarde.",
    );
  }
}

async function consumeMaintenanceChangeRateLimit(
  companyId: string,
  action: "maintenance_project_change" | "maintenance_plan_change",
) {
  const { data, error } = await supabase.rpc(
    "consume_maintenance_change_rate_limit",
    {
      p_company_id: companyId,
      p_action: action,
      p_limit: 1,
      p_window_seconds: 604800,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] maintenance change rate limit failed", {
      company_id: companyId,
      action,
      error,
    });

    const message = error.message || "No se pudo comprobar el límite de cambios de mantenimiento.";
    if (/rate.?limit|l[ií]mite|demasiad|too many/i.test(message)) {
      throw new HttpError(429, message);
    }

    throw new HttpError(500, "No se pudo comprobar el límite de cambios de mantenimiento.");
  }

  const result = asRecord(data);
  if (result.allowed === false) {
    throw new HttpError(
      429,
      `Has alcanzado el límite de solicitudes de ${
        action === "maintenance_project_change" ? "cambio de proyecto" : "cambio de plan"
      }. Vuelve a intentarlo más tarde.`,
    );
  }

  return result;
}

async function getContractForCompany(contractId: string, companyId: string) {
  const { data, error } = await supabase
    .from("maintenance_contracts")
    .select("*")
    .eq("id", contractId)
    .eq("company_id", companyId)
    .maybeSingle();

  if (error) {
    console.error("[maintenance-stripe] contract lookup failed", error);
    throw new HttpError(500, "No se pudo cargar el contrato");
  }

  if (!data) throw new HttpError(404, "Contrato de mantenimiento no encontrado");
  return data;
}

async function findOrCreateStripeCustomer(
  companyId: string,
  userEmail: string | undefined,
  company: Record<string, unknown>,
) {
  const search = await stripe.customers.search({
    query: `metadata['modira_company_id']:'${companyId}'`,
    limit: 1,
  });

  if (search.data.length > 0) {
    return search.data[0];
  }

  const name = companyDisplayName(company, "Cliente Modira");
  const taxId = companyTaxId(company);

  const customer = await stripe.customers.create({
    name,
    email: userEmail || undefined,
    metadata: {
      modira_company_id: companyId,
      ...(taxId ? { modira_tax_id: taxId } : {}),
    },
  });

  return customer;
}

function normalizeUrl(value: string | undefined, fallback: string): string {
  const candidate = value || fallback;
  const appUrl = requireEnv(MODIRA_APP_URL, "MODIRA_APP_URL");

  try {
    const parsed = new URL(candidate);
    const allowed = new URL(appUrl);

    if (parsed.origin !== allowed.origin) {
      throw new HttpError(400, "La URL de redirección no pertenece a Modira");
    }

    return parsed.toString();
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "URL de redirección no válida");
  }
}

function calculateCutoff(currentPeriodEnd: string | Date): Date {
  const date = new Date(currentPeriodEnd);
  return new Date(date.getTime() - 7 * 24 * 60 * 60 * 1000);
}

function canCancelWithoutNextCharge(currentPeriodEnd: string | Date): boolean {
  return new Date().getTime() <= calculateCutoff(currentPeriodEnd).getTime();
}

function isoDateFromUnix(timestamp: number | null | undefined): string | null {
  if (!timestamp) return null;
  return new Date(timestamp * 1000).toISOString().slice(0, 10);
}

function getRenewalDayFromPeriodStart(timestamp: number | null | undefined): number | null {
  if (!timestamp) return null;
  return new Date(timestamp * 1000).getUTCDate();
}

function getSubscriptionLocalState(
  subscription: Stripe.Subscription,
): "activo" | "pausado" | "cancelado" | null {
  if (subscription.status === "canceled" || subscription.status === "incomplete_expired") {
    return "cancelado";
  }

  if (
    subscription.status === "paused" ||
    subscription.pause_collection ||
    subscription.status === "past_due" ||
    subscription.status === "unpaid" ||
    subscription.status === "incomplete"
  ) {
    return "pausado";
  }

  if (subscription.status === "active" || subscription.status === "trialing") {
    return "activo";
  }

  return null;
}

// Stripe 18.5.0: algunos campos de Invoice han cambiado de forma/nombre
// entre versiones de la API. Estos helpers mantienen el acceso compatible
// sin depender de propiedades que el tipado concreto de Stripe no exponga.
function stripeInvoiceRecord(invoice: Stripe.Invoice): Record<string, any> {
  return invoice as unknown as Record<string, any>;
}

function getInvoiceId(invoice: Stripe.Invoice): string {
  const value = stripeInvoiceRecord(invoice).id;
  if (typeof value !== "string" || !value.trim()) {
    throw new Error("La factura Stripe no tiene un id válido");
  }
  return value;
}

function getInvoiceSubscriptionId(invoice: Stripe.Invoice): string | null {
  const record = stripeInvoiceRecord(invoice);

  // Formato clásico de Stripe:
  // invoice.subscription
  const value = record.subscription;

  if (typeof value === "string" && value.trim()) {
    return value;
  }

  if (
    value &&
    typeof value === "object" &&
    typeof value.id === "string" &&
    value.id.trim()
  ) {
    return value.id;
  }

  // Formato actual de Stripe:
  // invoice.parent.subscription_details.subscription
  const parentSubscription =
    record.parent?.subscription_details?.subscription;

  if (
    typeof parentSubscription === "string" &&
    parentSubscription.trim()
  ) {
    return parentSubscription;
  }

  if (
    parentSubscription &&
    typeof parentSubscription === "object" &&
    typeof parentSubscription.id === "string" &&
    parentSubscription.id.trim()
  ) {
    return parentSubscription.id;
  }

  return null;
}

function getInvoicePaymentIntentId(invoice: Stripe.Invoice): string | null {
  const value = stripeInvoiceRecord(invoice).payment_intent;
  if (typeof value === "string" && value.trim()) return value;
  if (value && typeof value === "object" && typeof value.id === "string") return value.id;
  return null;
}

function getInvoiceTaxAmounts(invoice: Stripe.Invoice): Array<{ amount?: number | null }> {
  const record = stripeInvoiceRecord(invoice);
  const value = record.total_tax_amounts ?? record.total_taxes ?? [];
  return Array.isArray(value) ? value : [];
}

function getAuthenticatedSupabaseClient(req: Request) {
  const anonKey = SUPABASE_ANON_KEY;
  if (!anonKey) {
    throw new HttpError(500, "SUPABASE_ANON_KEY no está configurada");
  }

  return createClient(SUPABASE_URL!, anonKey, {
    global: {
      headers: {
        Authorization: `Bearer ${getBearerToken(req)}`,
      },
    },
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}

async function updateContractBySubscription(
  subscription: Stripe.Subscription,
  extra: Record<string, unknown> = {},
) {
  const subscriptionId = subscription.id;
  const customerId = typeof subscription.customer === "string"
    ? subscription.customer
    : subscription.customer.id;

  const item = subscription.items.data[0];
  const priceId = typeof item?.price === "string" ? item.price : item?.price.id;
  const periodStart = item?.current_period_start ?? subscription.start_date ?? subscription.created;
  const periodEnd = item?.current_period_end ?? null;

  const payload: Record<string, unknown> = {
    stripe_customer_id: customerId,
    stripe_subscription_id: subscriptionId,
    stripe_subscription_item_id: item?.id ?? null,
    stripe_price_id: priceId ?? null,
    current_period_start: isoDateFromUnix(periodStart),
    current_period_end: isoDateFromUnix(periodEnd),
    renewal_day: getRenewalDayFromPeriodStart(periodStart),
    updated_at: new Date().toISOString(),
    ...extra,
  };

  const { data, error } = await supabase
    .from("maintenance_contracts")
    .update(payload)
    .eq("stripe_subscription_id", subscriptionId)
    .select("*")
    .maybeSingle();

  if (error) {
    console.error("[maintenance-stripe] contract sync failed", error);
    throw error;
  }

  return data;
}



async function getCustomProposalForCompany(
  proposalId: string,
  companyId: string,
  userId?: string,
) {
  if (!proposalId || !/^[0-9a-f-]{36}$/i.test(proposalId)) {
    throw new HttpError(400, "proposal_id no válido");
  }

  let query = supabase
    .from("maintenance_custom_proposals")
    .select("*")
    .eq("id", proposalId)
    .eq("company_id", companyId);

  if (userId) {
    query = query.eq("user_id", userId);
  }

  const { data, error } = await query.maybeSingle();

  if (error) {
    console.error("[maintenance-stripe] custom proposal lookup failed", error);
    throw new HttpError(500, "No se pudo cargar la propuesta personalizada");
  }

  if (!data) {
    throw new HttpError(404, "Propuesta personalizada no encontrada");
  }

  return data as Record<string, any>;
}

async function ensureCustomProposalAccepted(
  proposal: Record<string, any>,
  userId: string,
) {
  if (proposal.status === "accepted") return proposal;

  if (proposal.status !== "quoted") {
    throw new HttpError(
      409,
      "La propuesta personalizada debe estar presupuestada antes de poder aceptarla.",
    );
  }

  const { data, error } = await supabase.rpc(
    "accept_custom_maintenance_proposal_for_user",
    {
      p_proposal_id: proposal.id,
      p_user_id: userId,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] custom proposal acceptance failed", error);
    throw new HttpError(
      409,
      error.message || "No se pudo aceptar la propuesta personalizada",
    );
  }

  return (data || proposal) as Record<string, any>;
}

function customProposalQuotedAmountCents(proposal: Record<string, any>): number {
  const amount = Number(proposal.quoted_monthly_price);

  if (!Number.isFinite(amount) || amount <= 0) {
    throw new HttpError(
      409,
      "La propuesta personalizada no tiene un precio mensual válido.",
    );
  }

  const cents = Math.round(amount * 100);

  if (cents <= 0) {
    throw new HttpError(
      409,
      "El precio mensual acordado no es válido.",
    );
  }

  return cents;
}

function assertCustomProposalQuoteStillValid(
  proposal: Record<string, any>,
) {
  if (proposal.status !== "accepted") {
    throw new HttpError(409, "La propuesta personalizada todavía no está aceptada.");
  }

  if (!proposal.quoted_monthly_price) {
    throw new HttpError(409, "La propuesta personalizada no tiene un precio acordado.");
  }

  if (proposal.quoted_valid_until) {
    const validUntil = new Date(`${proposal.quoted_valid_until}T23:59:59.999Z`);
    if (
      Number.isFinite(validUntil.getTime()) &&
      validUntil.getTime() < Date.now()
    ) {
      throw new HttpError(
        409,
        "La propuesta personalizada ha caducado. Solicita a Modira una nueva propuesta.",
      );
    }
  }
}

async function getOrCreateCustomStripePrice(
  proposal: Record<string, any>,
  plan: Record<string, any>,
  company: Record<string, unknown>,
) {
  assertCustomProposalQuoteStillValid(proposal);

  const amountCents = customProposalQuotedAmountCents(proposal);
  const currency = String(proposal.quoted_currency || plan.moneda || "EUR").toLowerCase();

  if (!/^[a-z]{3}$/.test(currency)) {
    throw new HttpError(409, "La moneda de la propuesta personalizada no es válida.");
  }

  if (proposal.stripe_price_id) {
    try {
      const existingPrice = await stripe.prices.retrieve(proposal.stripe_price_id);

      if (
        !existingPrice.active ||
        existingPrice.type !== "recurring" ||
        existingPrice.recurring?.interval !== "month" ||
        existingPrice.unit_amount !== amountCents ||
        String(existingPrice.currency || "").toLowerCase() !== currency
      ) {
        throw new HttpError(
          409,
          "El precio Stripe asociado a la propuesta no coincide con el importe acordado.",
        );
      }

      return {
        productId:
          typeof existingPrice.product === "string"
            ? existingPrice.product
            : existingPrice.product?.id || proposal.stripe_product_id || null,
        price: existingPrice,
      };
    } catch (error) {
      if (error instanceof HttpError) throw error;
      console.error("[maintenance-stripe] custom Stripe price retrieval failed", error);
      throw new HttpError(409, "No se pudo validar el precio Stripe de la propuesta personalizada.");
    }
  }

  const companyName = companyDisplayName(company, "Cliente Modira");
  const product = await stripe.products.create({
    name: `Modira Care Custom — ${companyName}`,
    description:
      typeof proposal.quoted_description === "string" && proposal.quoted_description.trim()
        ? proposal.quoted_description.trim().slice(0, 500)
        : "Plan de mantenimiento personalizado de Modira",
    metadata: {
      modira_company_id: proposal.company_id,
      modira_user_id: proposal.user_id,
      modira_plan_id: plan.id,
      modira_plan_code: plan.code,
      modira_custom_proposal_id: proposal.id,
      modira_terms_version: MAINTENANCE_TERMS_VERSION,
    },
  });

  const price = await stripe.prices.create({
    product: product.id,
    unit_amount: amountCents,
    currency,
    recurring: {
      interval: "month",
    },
    metadata: {
      modira_company_id: proposal.company_id,
      modira_user_id: proposal.user_id,
      modira_plan_id: plan.id,
      modira_plan_code: plan.code,
      modira_custom_proposal_id: proposal.id,
      modira_terms_version: MAINTENANCE_TERMS_VERSION,
    },
  });

  const { error } = await supabase
    .from("maintenance_custom_proposals")
    .update({
      stripe_product_id: product.id,
      stripe_price_id: price.id,
      updated_at: new Date().toISOString(),
    })
    .eq("id", proposal.id)
    .eq("company_id", proposal.company_id);

  if (error) {
    console.error("[maintenance-stripe] custom proposal Stripe references update failed", error);

    try {
      await stripe.prices.update(price.id, { active: false });
    } catch (priceError) {
      console.error("[maintenance-stripe] could not deactivate orphan custom price", priceError);
    }

    try {
      await stripe.products.update(product.id, { active: false });
    } catch (productError) {
      console.error("[maintenance-stripe] could not deactivate orphan custom product", productError);
    }

    throw error;
  }

  return {
    productId: product.id,
    price,
  };
}

async function acceptCustomMaintenanceProposal(
  req: Request,
  body: Record<string, unknown>,
) {
  const { user, companyId } = await requireActiveUser(req);
  const company = await getCompany(companyId);
  assertCurrentFiscalData(company);

  const maintenanceIva = await getMaintenanceIvaConfiguration(
  companyId,
);

const maintenanceTaxRate =
  await getOrCreateMaintenanceTaxRate(
    maintenanceIva.ivaAplicado,
    maintenanceIva.ivaPorcentaje,
  );

  const proposalId = String(body.proposal_id || "").trim();
  let proposal = await getCustomProposalForCompany(
    proposalId,
    companyId,
    user.id,
  );

  const plan = await getPlanByCode("custom");

  if (!plan.es_personalizado || plan.stripe_price_id) {
    throw new HttpError(409, "El plan Custom no está configurado correctamente.");
  }

  if (String(proposal.plan_id) !== String(plan.id)) {
    throw new HttpError(409, "La propuesta no pertenece al plan Custom.");
  }

  proposal = await ensureCustomProposalAccepted(proposal, user.id);

  assertCustomProposalQuoteStillValid(proposal);

  const projectId = String(body.project_id || "").trim();
  if (!projectId) {
    throw new HttpError(
      400,
      "Debes seleccionar un proyecto para contratar el mantenimiento.",
    );
  }

 await consumeMaintenanceContractRateLimit(companyId);
console.info("[maintenance-stripe] create_checkout_session:rate_limit_ok");

const lock = await acquireCheckoutLock(companyId, user.id, plan.id);
console.info("[maintenance-stripe] create_checkout_session:lock_ok", {
  company_id: companyId,
});

await assertProjectAvailableForMaintenance(projectId, companyId);
console.info("[maintenance-stripe] create_checkout_session:project_ok", {
  project_id: projectId,
});

  try {
    const customer = await findOrCreateStripeCustomer(
      companyId,
      user.email,
      company,
    );

    const { price } = await getOrCreateCustomStripePrice(
      proposal,
      plan,
      company,
    );

    const defaultSuccess = `${requireEnv(MODIRA_APP_URL, "MODIRA_APP_URL")}/employee/maintenance?checkout=success&custom_proposal=${proposal.id}`;
    const defaultCancel = `${requireEnv(MODIRA_APP_URL, "MODIRA_APP_URL")}/employee/maintenance?checkout=cancelled&custom_proposal=${proposal.id}`;

    const successUrl = normalizeUrl(
      typeof body.success_url === "string" ? body.success_url : undefined,
      defaultSuccess,
    );

    const cancelUrl = normalizeUrl(
      typeof body.cancel_url === "string" ? body.cancel_url : undefined,
      defaultCancel,
    );

    console.info("[maintenance-stripe] create_checkout_session:stripe_create");
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customer.id,
      line_items: [{
  price: price.id,
  quantity: 1,
  ...(maintenanceTaxRate
    ? {
        tax_rates: [maintenanceTaxRate.id],
      }
    : {}),
}],
      billing_address_collection: "required",
      tax_id_collection: { enabled: true },
      automatic_tax: { enabled: false },
      customer_update: {
        address: "auto",
        name: "auto",
      },
      locale: "es",
      client_reference_id: companyId,
      success_url: successUrl,
      cancel_url: cancelUrl,
      subscription_data: {
        metadata: {
          modira_company_id: companyId,
          modira_user_id: user.id,
          modira_plan_id: plan.id,
          modira_plan_code: plan.code,
          modira_project_id: projectId,
          modira_custom_proposal_id: proposal.id,
          
          modira_terms_version: MAINTENANCE_TERMS_VERSION,
          modira_iva_aplicado:
  String(maintenanceIva.ivaAplicado),

modira_iva_porcentaje:
  String(maintenanceIva.ivaPorcentaje),
        },
      },
      metadata: {
        modira_company_id: companyId,
        modira_user_id: user.id,
        modira_plan_id: plan.id,
        modira_plan_code: plan.code,
        modira_project_id: projectId,
        modira_custom_proposal_id: proposal.id,
        modira_terms_version: MAINTENANCE_TERMS_VERSION,
        modira_iva_aplicado:
  String(maintenanceIva.ivaAplicado),

modira_iva_porcentaje:
  String(maintenanceIva.ivaPorcentaje),
      },
    });

    await rememberCheckoutSession(companyId, session.id);
    console.info("[maintenance-stripe] create_checkout_session:success", {
      checkout_session_id: session.id,
    });

    return json({
      ok: true,
      custom: true,
      proposal_id: proposal.id,
      checkout_session_id: session.id,
      checkout_url: session.url,
      stripe_price_id: price.id,
      agreed_monthly_price: Number(proposal.quoted_monthly_price),
      currency: String(proposal.quoted_currency || plan.moneda || "EUR").toUpperCase(),
      terms_version: MAINTENANCE_TERMS_VERSION,
    });
  } catch (error) {
    await releaseCheckoutLock(companyId);
    throw error;
  }
}
async function getMaintenanceIvaConfiguration(
  companyId: string,
) {
  const { data, error } = await supabase
    .from("companies")
    .select(`
      id,
      iva_recomendado_aplicado,
      iva_recomendado_porcentaje
    `)
    .eq("id", companyId)
    .single();

  if (error) {
    console.error(
      "[maintenance-stripe] company IVA configuration lookup failed",
      error,
    );
    throw new HttpError(
      500,
      "No se pudo obtener la configuración de IVA de la empresa",
    );
  }

  const ivaAplicado =
    data?.iva_recomendado_aplicado !== false;

  const ivaPorcentaje = Number(
    data?.iva_recomendado_porcentaje ?? 21,
  );

  if (
    !Number.isFinite(ivaPorcentaje) ||
    ivaPorcentaje < 0 ||
    ivaPorcentaje > 100
  ) {
    throw new HttpError(
      409,
      "La configuración de IVA de la empresa no es válida",
    );
  }

  return {
    ivaAplicado,
    ivaPorcentaje: Number(ivaPorcentaje.toFixed(2)),
  };
}


async function getOrCreateMaintenanceTaxRate(
  ivaAplicado: boolean,
  ivaPorcentaje: number,
) {
  /*
   * Si no se aplica IVA, no necesitamos Tax Rate.
   */
  if (!ivaAplicado || ivaPorcentaje <= 0) {
    return null;
  }

  const normalizedPercentage =
    Number(ivaPorcentaje.toFixed(2));

  /*
   * Buscamos primero un Tax Rate existente creado por Modira
   * para evitar crear uno nuevo cada vez que un cliente contrata.
   */
  const existingRates = await stripe.taxRates.list({
    active: true,
    limit: 100,
  });

  const existing = existingRates.data.find((rate) => {
    return (
      rate.metadata?.modira_maintenance === "true" &&
      rate.metadata?.modira_iva_porcentaje ===
        String(normalizedPercentage) &&
      rate.inclusive === true &&
      rate.percentage === normalizedPercentage
    );
  });

  if (existing) {
    return existing;
  }

  /*
   * El precio comercial de mantenimiento es FINAL IVA incluido.
   *
   * Por eso el Tax Rate debe ser inclusive.
   */
  const taxRate = await stripe.taxRates.create({
    display_name: "IVA",
    description:
      `IVA mantenimiento Modira ${normalizedPercentage}%`,
    percentage: normalizedPercentage,
    inclusive: true,
    country: "ES",
    tax_type: "vat",
    metadata: {
      modira_maintenance: "true",
      modira_iva_porcentaje:
        String(normalizedPercentage),
    },
  });

  return taxRate;
}
async function assertPlanMatchesStripePrice(plan: Record<string, any>) {
  if (plan.es_personalizado || !plan.stripe_price_id) {
    throw new HttpError(400, "El plan seleccionado requiere una contratación personalizada");
  }

  const price = await stripe.prices.retrieve(plan.stripe_price_id);

  if (!price.active) {
    throw new HttpError(409, "El precio Stripe del plan no está activo");
  }

  const expectedAmount = Math.round(Number(plan.precio) * 100);
  if (
    price.unit_amount === null ||
    price.unit_amount !== expectedAmount
  ) {
    console.error("[maintenance-stripe] price mismatch", {
      plan_id: plan.id,
      stripe_price_id: price.id,
      database_amount: plan.precio,
      stripe_amount: price.unit_amount,
    });
    throw new HttpError(
      409,
      "El precio configurado en Modira no coincide con el precio Stripe del plan. La contratación se ha bloqueado.",
    );
  }

  if ((price.currency || "").toUpperCase() !== String(plan.moneda || "").toUpperCase()) {
    throw new HttpError(
      409,
      "La moneda del plan no coincide con la moneda configurada en Stripe. La contratación se ha bloqueado.",
    );
  }

  if (price.type !== "recurring" || price.recurring?.interval !== "month") {
    throw new HttpError(
      409,
      "El precio Stripe del plan no es una suscripción mensual válida.",
    );
  }

  return price;
}

async function cleanupExpiredCheckoutLocks() {
  const { error } = await supabase
    .from("maintenance_checkout_locks")
    .delete()
    .lt("expires_at", new Date().toISOString());

  if (error) {
    console.error("[maintenance-stripe] checkout lock cleanup failed", error);
    throw new HttpError(500, "No se pudo preparar la contratación");
  }
}

async function acquireCheckoutLock(
  companyId: string,
  userId: string,
  planId: string,
) {
  await cleanupExpiredCheckoutLocks();

  const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();

  const insertLock = async () =>
    await supabase
      .from("maintenance_checkout_locks")
      .insert({
        company_id: companyId,
        user_id: userId,
        plan_id: planId,
        expires_at: expiresAt,
      })
      .select("*")
      .maybeSingle();

  let { data, error } = await insertLock();

  if (error) {
    const existing = await supabase
      .from("maintenance_checkout_locks")
      .select("company_id, expires_at, stripe_checkout_session_id")
      .eq("company_id", companyId)
      .maybeSingle();

    if (existing.error) {
      console.error(
        "[maintenance-stripe] checkout lock lookup failed",
        existing.error,
      );
      throw existing.error;
    }

    if (existing.data) {
      const existingExpiresAt = new Date(existing.data.expires_at).getTime();

      // A stale lock must never prevent a new checkout, even if the initial
      // cleanup could not remove it for any reason.
      if (
        Number.isFinite(existingExpiresAt) &&
        existingExpiresAt <= Date.now()
      ) {
        const { error: deleteError } = await supabase
          .from("maintenance_checkout_locks")
          .delete()
          .eq("company_id", companyId);

        if (deleteError) {
          console.error(
            "[maintenance-stripe] stale checkout lock delete failed",
            deleteError,
          );
          throw new HttpError(
            500,
            "No se pudo liberar una contratación anterior. Inténtalo de nuevo.",
          );
        }

        ({ data, error } = await insertLock());
      }
    }

    if (error && existing.data && data == null) {
      const refreshed = await supabase
        .from("maintenance_checkout_locks")
        .select("company_id, expires_at, stripe_checkout_session_id")
        .eq("company_id", companyId)
        .maybeSingle();

      if (refreshed.data) {
        throw new HttpError(
          409,
          "Ya existe una contratación de mantenimiento en curso para esta empresa. Espera unos minutos y vuelve a intentarlo.",
        );
      }
    }

    if (error) {
      console.error("[maintenance-stripe] checkout lock insert failed", error);
      throw error;
    }
  }

  if (!data) {
    throw new HttpError(
      500,
      "No se pudo preparar la contratación de mantenimiento.",
    );
  }

  return data;
}

async function releaseCheckoutLock(companyId: string) {
  await supabase
    .from("maintenance_checkout_locks")
    .delete()
    .eq("company_id", companyId);
}

async function rememberCheckoutSession(companyId: string, sessionId: string) {
  const { error } = await supabase
    .from("maintenance_checkout_locks")
    .update({
      stripe_checkout_session_id: sessionId,
      expires_at: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
    })
    .eq("company_id", companyId);

  if (error) throw error;
}

async function getContractBySubscription(subscriptionId: string) {
  const { data, error } = await supabase
    .from("maintenance_contracts")
    .select("*")
    .eq("stripe_subscription_id", subscriptionId)
    .maybeSingle();

  if (error) throw error;
  return data;
}

async function createOrGetContractFromSubscription(
  subscription: Stripe.Subscription,
  cancelIfIntegrityFails = true,
) {
  const metadata = subscription.metadata || {};
  const companyId = metadata.modira_company_id;
  const userId = metadata.modira_user_id;
  const planId = metadata.modira_plan_id;
  const projectId = metadata.modira_project_id;

  if (!companyId || !userId || !planId) {
    throw new Error("La suscripción Stripe no contiene los metadatos obligatorios de Modira");
  }

  if (!projectId) {
    throw new Error("La suscripción Stripe no contiene modira_project_id");
  }

  const existing = await getContractBySubscription(subscription.id);
  if (existing) {
    return existing;
  }

  await getProjectForCompany(projectId, companyId);

  const existingProjectContract = await getActiveContractForProject(projectId);
  if (existingProjectContract && existingProjectContract.stripe_subscription_id !== subscription.id) {
    if (cancelIfIntegrityFails) {
      try {
        await stripe.subscriptions.cancel(subscription.id);
      } catch (cancelError) {
        console.error(
          "[maintenance-stripe] could not cancel duplicate project subscription",
          cancelError,
        );
      }
      await releaseCheckoutLock(companyId);
    }

    throw new HttpError(
      409,
      "El proyecto ya tiene otro contrato de mantenimiento activo o pausado.",
    );
  }

  const company = await getCompany(companyId);
  try {
    assertCurrentFiscalData(company);
  } catch (error) {
    if (cancelIfIntegrityFails) {
      try {
        await stripe.subscriptions.cancel(subscription.id);
      } catch (cancelError) {
        console.error("[maintenance-stripe] could not cancel invalid subscription", cancelError);
      }
      await releaseCheckoutLock(companyId);
    }
    throw error;
  }
const maintenanceIvaAplicado =
  metadata.modira_iva_aplicado !== "false";

const maintenanceIvaPorcentaje = Number(
  metadata.modira_iva_porcentaje ?? 21,
);

if (
  !Number.isFinite(maintenanceIvaPorcentaje) ||
  maintenanceIvaPorcentaje < 0 ||
  maintenanceIvaPorcentaje > 100
) {
  throw new Error("La suscripción Stripe contiene una configuración de IVA no válida");
}
  const planQuery = await supabase
    .from("maintenance_plans")
    .select("*")
    .eq("id", planId)
    .eq("activo", true)
    .maybeSingle();

  if (planQuery.error) throw planQuery.error;
  if (!planQuery.data) throw new Error("El plan asociado a la suscripción no existe o está inactivo");

  const plan = planQuery.data as Record<string, any>;

  const customProposalId = String(metadata.modira_custom_proposal_id || "").trim();
  const isCustom = Boolean(plan.es_personalizado);

  let customProposal: Record<string, any> | null = null;

  if (isCustom) {
    if (!customProposalId) {
      throw new Error("La suscripción Custom no contiene modira_custom_proposal_id");
    }

    customProposal = await getCustomProposalForCompany(
      customProposalId,
      companyId,
      userId,
    );

    if (String(customProposal.plan_id) !== String(plan.id)) {
      throw new Error("La propuesta Custom no pertenece al plan asociado a la suscripción");
    }

    assertCustomProposalQuoteStillValid(customProposal);
  } else {
    await assertPlanMatchesStripePrice(plan);

    if (customProposalId) {
      throw new Error("Una suscripción de un plan fijo no puede contener una propuesta Custom");
    }
  }


  const item = subscription.items.data[0];
  const priceId = typeof item?.price === "string" ? item.price : item?.price.id;
  const start = item?.current_period_start ?? subscription.start_date ?? subscription.created;
  const end = item?.current_period_end ?? null;
  const customerId = typeof subscription.customer === "string"
    ? subscription.customer
    : subscription.customer.id;

  const agreedMonthlyPrice = isCustom
    ? Number(customProposal?.quoted_monthly_price)
    : Number(plan.precio);

  if (!Number.isFinite(agreedMonthlyPrice) || agreedMonthlyPrice <= 0) {
    throw new Error("El importe mensual del contrato no es válido");
  }

  const insert = await supabase
    .from("maintenance_contracts")
    .insert({
      user_id: userId,
      company_id: companyId,
      plan_id: plan.id,
      iva_aplicado: maintenanceIvaAplicado,
iva_porcentaje: maintenanceIvaPorcentaje,
iva_source: "company_default",

iva_configured_by:
  company.iva_recomendado_updated_by ?? null,
iva_configured_at:
  company.iva_recomendado_updated_at ?? null,
      nombre_plan: plan.nombre,
      descripcion: isCustom
        ? (customProposal?.quoted_description || plan.descripcion)
        : plan.descripcion,
      precio: agreedMonthlyPrice,
      moneda: isCustom
        ? (customProposal?.quoted_currency || plan.moneda)
        : plan.moneda,
      periodicidad: plan.periodicidad,
      estado: "activo",
      fecha_inicio: isoDateFromUnix(subscription.start_date ?? subscription.created),
      fecha_fin: null,
      current_period_start: isoDateFromUnix(start),
      current_period_end: isoDateFromUnix(end),
      renewal_day: getRenewalDayFromPeriodStart(start),
      stripe_customer_id: customerId,
      stripe_subscription_id: subscription.id,
      stripe_subscription_item_id: item?.id ?? null,
      stripe_price_id: priceId ?? null,
      ...(isCustom
        ? {
            maintenance_custom_proposal_id: customProposal?.id,
            agreed_monthly_price: agreedMonthlyPrice,
            scope_snapshot: customProposal?.quote_snapshot || {
              quoted_monthly_price: customProposal?.quoted_monthly_price,
              quoted_currency: customProposal?.quoted_currency,
              quoted_hours_monthly: customProposal?.quoted_hours_monthly,
              quoted_scope_level: customProposal?.quoted_scope_level,
              quoted_service_level: customProposal?.quoted_service_level,
              quoted_sla: customProposal?.quoted_sla,
              quoted_response_time: customProposal?.quoted_response_time,
              quoted_support_hours: customProposal?.quoted_support_hours,
              quoted_description: customProposal?.quoted_description,
              quoted_terms: customProposal?.quoted_terms,
              captured_at: new Date().toISOString(),
            },
          }
        : {}),
      contracted_at: new Date().toISOString(),
      terms_version: MAINTENANCE_TERMS_VERSION,
      plan_snapshot: {
        code: plan.code,
        nombre: plan.nombre,
        descripcion: isCustom
          ? (customProposal?.quoted_description || plan.descripcion)
          : plan.descripcion,
        precio_catalogo: plan.precio,
        precio_acordado: agreedMonthlyPrice,
        moneda: isCustom
          ? (customProposal?.quoted_currency || plan.moneda)
          : plan.moneda,
        periodicidad: plan.periodicidad,
        iva_aplicado: maintenanceIvaAplicado,
iva_porcentaje: maintenanceIvaPorcentaje,
iva_source: "company_default",
        ...(isCustom
          ? {
              custom_proposal_id: customProposal?.id,
              custom_proposal_status: customProposal?.status,
              quoted_valid_until: customProposal?.quoted_valid_until ?? null,
            }
          : {}),
        captured_at: new Date().toISOString(),
      },
    })
    .select("*")
    .single();

  if (insert.error) {
    const reread = await getContractBySubscription(subscription.id);
    if (reread) return reread;

    const duplicateProject = await getActiveContractForProject(projectId);
    if (duplicateProject && duplicateProject.stripe_subscription_id !== subscription.id) {
      try {
        await stripe.subscriptions.cancel(subscription.id);
      } catch (cancelError) {
        console.error(
          "[maintenance-stripe] duplicate project subscription cancellation failed",
          cancelError,
        );
      }
      await releaseCheckoutLock(companyId);
      throw new HttpError(
        409,
        "Se detectó una segunda suscripción de mantenimiento para el proyecto.",
      );
    }

    throw insert.error;
  }
const { error: projectAssignmentError } = await supabase
  .from("maintenance_contract_projects")
  .insert({
    maintenance_contract_id: insert.data.id,
    project_id: projectId,
  });

if (projectAssignmentError) {
  console.error(
    "[maintenance-stripe] maintenance contract project assignment failed",
    projectAssignmentError,
  );

  try {
    await stripe.subscriptions.cancel(subscription.id);
  } catch (cancelError) {
    console.error(
      "[maintenance-stripe] could not cancel subscription after project assignment failure",
      cancelError,
    );
  }

  await supabase
    .from("maintenance_contracts")
    .delete()
    .eq("id", insert.data.id);

  await releaseCheckoutLock(companyId);

  throw new HttpError(
    409,
    "No se pudo asociar el contrato al proyecto seleccionado.",
  );
}
  if (isCustom && customProposal?.id) {
    const { error: proposalLinkError } = await supabase
      .from("maintenance_custom_proposals")
      .update({
        stripe_customer_id: customerId,
        stripe_subscription_id: subscription.id,
        stripe_price_id: priceId ?? customProposal.stripe_price_id ?? null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", customProposal.id)
      .eq("company_id", companyId);

    if (proposalLinkError) {
      console.error(
        "[maintenance-stripe] custom proposal subscription link update failed",
        proposalLinkError,
      );
      // The contract is already the source of truth for the active subscription.
      // Do not cancel a valid Stripe subscription because this auxiliary
      // proposal-reference update failed.
    }
  }

  await releaseCheckoutLock(companyId);
  return insert.data;
}

async function pauseBillingForFiscalProblem(
  invoice: Stripe.Invoice,
  subscription: Stripe.Subscription,
  companyId: string,
  reason: string,
) {
  try {
    await stripe.invoices.update(getInvoiceId(invoice), {
      auto_advance: false,
    });
  } catch (error) {
    console.error("[maintenance-stripe] could not stop invoice auto-advance", error);
  }

  try {
    await stripe.subscriptions.update(subscription.id, {
      pause_collection: { behavior: "keep_as_draft" },
    });
  } catch (error) {
    console.error("[maintenance-stripe] could not pause subscription collection", error);
    throw error;
  }

  await supabase
    .from("maintenance_contracts")
    .update({
      estado: "pausado",
      updated_at: new Date().toISOString(),
    })
    .eq("stripe_subscription_id", subscription.id);

  console.warn("[maintenance-stripe] billing paused for fiscal data", {
    company_id: companyId,
    subscription_id: subscription.id,
    invoice_id: getInvoiceId(invoice),
    reason,
  });
}

async function validateInvoiceFiscalState(
  invoice: Stripe.Invoice,
  subscription: Stripe.Subscription | null,
) {
  if (!subscription) return true;

  const metadata = subscription.metadata || {};
  const companyId = metadata.modira_company_id;
  if (!companyId) return true;

  const company = await getCompany(companyId);
  const missing = missingFiscalFields(company);

  if (missing.length === 0) return true;

  await pauseBillingForFiscalProblem(
    invoice,
    subscription,
    companyId,
    `Faltan: ${missing.join(", ")}`,
  );

  return false;
}

async function resumeBillingAfterFiscalUpdate(
  req: Request,
  body: Record<string, unknown>,
) {
  const { companyId } = await requireActiveUser(req);
  const contractId = String(body.contract_id || "");
  const contract = await getContractForCompany(contractId, companyId);

  if (!contract.stripe_subscription_id) {
    throw new HttpError(409, "El contrato no tiene una suscripción Stripe");
  }

  const company = await getCompany(companyId);
  assertCurrentFiscalData(company);

  const subscription = await stripe.subscriptions.retrieve(contract.stripe_subscription_id);

  if (subscription.status === "canceled") {
    throw new HttpError(409, "La suscripción Stripe ya está cancelada");
  }

  await stripe.subscriptions.update(contract.stripe_subscription_id, {
    pause_collection: null,
  });

  const { data, error } = await supabase
    .from("maintenance_contracts")
    .update({
      estado: "activo",
      updated_at: new Date().toISOString(),
    })
    .eq("id", contract.id)
    .eq("company_id", companyId)
    .select("*")
    .single();

  if (error) throw error;

  return json({
    ok: true,
    resumed: true,
    contract: data,
  });
}

async function reconcileSubscription(
  req: Request,
  body: Record<string, unknown>,
) {
  const { companyId } = await requireActiveUser(req);
  const subscriptionId = String(body.subscription_id || "").trim();

  if (!/^sub_[A-Za-z0-9]+$/.test(subscriptionId)) {
    throw new HttpError(400, "subscription_id no válido");
  }

  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const metadataCompanyId = subscription.metadata?.modira_company_id;

  if (metadataCompanyId !== companyId) {
    throw new HttpError(403, "La suscripción no pertenece a la empresa actual");
  }

  const contract = await createOrGetContractFromSubscription(subscription, true);

  await handleSubscriptionUpdated(subscription);

  return json({
    ok: true,
    reconciled: true,
    contract,
    stripe_subscription_id: subscription.id,
  });
}

async function createCheckoutSession(req: Request, body: Record<string, unknown>) {
  console.info("[maintenance-stripe] create_checkout_session:start");
  const { user, companyId } = await requireActiveUser(req);
  console.info("[maintenance-stripe] create_checkout_session:auth", {
    company_id: companyId,
    user_id: user.id,
  });
  const company = await getCompany(companyId);

  // Fiscal data is checked against the CURRENT companies row.
  // Pending fiscal requests do not count until 066 has applied them.
  assertCurrentFiscalData(company);

  const maintenanceIva = await getMaintenanceIvaConfiguration(companyId);

const maintenanceTaxRate = await getOrCreateMaintenanceTaxRate(
  maintenanceIva.ivaAplicado,
  maintenanceIva.ivaPorcentaje,
);

  const planCode = String(body.plan_code || "").trim().toLowerCase();
  const plan = await getPlanByCode(planCode);
  console.info("[maintenance-stripe] create_checkout_session:plan", {
    plan_code: planCode,
    plan_id: plan.id,
  });

  const projectId = String(body.project_id || "").trim();
  if (!projectId) {
    throw new HttpError(
      400,
      "Debes seleccionar un proyecto para contratar el mantenimiento.",
    );
  }

  

  if (plan.es_personalizado) {
    // The Custom flow is quote-driven. Reuse this action as a compatibility
    // entry point so the frontend may call create_checkout_session with
    // plan_code=custom and proposal_id, while the dedicated action remains
    // available for clarity.
    return await acceptCustomMaintenanceProposal(req, body);
  }

  if (!plan.stripe_price_id) {
    throw new HttpError(409, "El plan seleccionado no tiene un precio Stripe configurado");
  }

  await assertPlanMatchesStripePrice(plan);

  await consumeMaintenanceContractRateLimit(companyId);
  console.info("[maintenance-stripe] create_checkout_session:rate_limit_ok");

  const lock = await acquireCheckoutLock(companyId, user.id, plan.id);
  await assertProjectAvailableForMaintenance(projectId, companyId);
  console.info("[maintenance-stripe] create_checkout_session:project_ok", {
    project_id: projectId,
  });
  console.info("[maintenance-stripe] create_checkout_session:lock_ok", {
    company_id: companyId,
  });

  try {
    const customer = await findOrCreateStripeCustomer(
      companyId,
      user.email,
      company,
    );

    const defaultSuccess = `${requireEnv(MODIRA_APP_URL, "MODIRA_APP_URL")}/employee/maintenance?checkout=success`;
    const defaultCancel = `${requireEnv(MODIRA_APP_URL, "MODIRA_APP_URL")}/employee/maintenance?checkout=cancelled`;

    const successUrl = normalizeUrl(
      typeof body.success_url === "string" ? body.success_url : undefined,
      defaultSuccess,
    );
    const cancelUrl = normalizeUrl(
      typeof body.cancel_url === "string" ? body.cancel_url : undefined,
      defaultCancel,
    );

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customer.id,
      line_items: [{
  price: plan.stripe_price_id,
  quantity: 1,
  ...(maintenanceTaxRate
    ? {
        tax_rates: [maintenanceTaxRate.id],
      }
    : {}),
}],
billing_address_collection: "required",
tax_id_collection: { enabled: true },
automatic_tax: { enabled: false },
      customer_update: {
  address: "auto",
  name: "auto",
},
      locale: "es",
      client_reference_id: companyId,
      success_url: successUrl,
      cancel_url: cancelUrl,
      subscription_data: {
        metadata: {
          modira_company_id: companyId,
          modira_user_id: user.id,
          modira_plan_id: plan.id,
          modira_plan_code: plan.code,
          modira_project_id: projectId,
          modira_iva_aplicado:
  String(maintenanceIva.ivaAplicado),

modira_iva_porcentaje:
  String(maintenanceIva.ivaPorcentaje),
        },
      },
      metadata: {
        modira_company_id: companyId,
        modira_user_id: user.id,
        modira_plan_id: plan.id,
        modira_plan_code: plan.code,
        modira_project_id: projectId,
        modira_terms_version: MAINTENANCE_TERMS_VERSION,
        modira_iva_aplicado:
  String(maintenanceIva.ivaAplicado),

modira_iva_porcentaje:
  String(maintenanceIva.ivaPorcentaje),
      },
    });

    await rememberCheckoutSession(companyId, session.id);

    return json({
      ok: true,
      checkout_session_id: session.id,
      checkout_url: session.url,
      terms_version: MAINTENANCE_TERMS_VERSION,
    });
  } catch (error) {
    await releaseCheckoutLock(companyId);
    throw error;
  }
}

async function requestCancellation(req: Request, body: Record<string, unknown>) {
  const { companyId } = await requireActiveUser(req);
  const contractId = String(body.contract_id || "");
  const contract = await getContractForCompany(contractId, companyId);

  if (!contract.stripe_subscription_id) {
    throw new HttpError(409, "El contrato todavía no tiene una suscripción Stripe");
  }

  if (!contract.current_period_end) {
    throw new HttpError(409, "El contrato no tiene un periodo de facturación válido");
  }

  if (contract.cancel_at_period_end) {
    return json({
      ok: true,
      already_scheduled: true,
      cancel_effective_at: contract.cancel_effective_at,
    });
  }

  const allowedBeforeNextCharge = canCancelWithoutNextCharge(contract.current_period_end);

  const subscription = await stripe.subscriptions.retrieve(contract.stripe_subscription_id);

  // A pending plan change is represented by a Stripe Subscription Schedule.
  // Cancellation takes precedence, so release that schedule before applying
  // the cancellation to the underlying subscription.
  if (subscription.schedule) {
    const scheduleId = typeof subscription.schedule === "string"
      ? subscription.schedule
      : subscription.schedule.id;
    const schedule = await stripe.subscriptionSchedules.retrieve(scheduleId);
    if (schedule.status === "active" || schedule.status === "not_started") {
      await stripe.subscriptionSchedules.release(scheduleId);
    }
  }

  // Business rule agreed for Modira: 7 natural days before renewal.
  // If the request arrives inside the cutoff window, the current period
  // is already committed and Stripe must keep the subscription for one
  // more billing cycle.
  const effectiveAt = allowedBeforeNextCharge
    ? contract.current_period_end
    : null;

  if (allowedBeforeNextCharge) {
    const updated = await stripe.subscriptions.update(contract.stripe_subscription_id, {
      cancel_at_period_end: true,
    });

    const { data, error } = await supabase
      .from("maintenance_contracts")
      .update({
        cancel_at_period_end: true,
        cancel_requested_at: new Date().toISOString(),
        cancel_effective_at: contract.current_period_end,
        pending_plan_id: null,
        pending_change_effective_at: null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", contract.id)
      .eq("company_id", companyId)
      .select("*")
      .single();

    if (error) throw error;

    return json({
      ok: true,
      scheduled: true,
      charged_next_period: false,
      cancel_effective_at: effectiveAt,
      stripe_subscription_status: updated.status,
    });
  }

  // Too late for the current renewal: we intentionally do NOT call
  // Stripe cancel_at_period_end yet. The next renewal is charged and
  // the subscription will then end at the following period boundary.
  // We store the request so Modira knows the customer's intent.
  const nextPeriodEnd = new Date(contract.current_period_end);
  nextPeriodEnd.setUTCMonth(nextPeriodEnd.getUTCMonth() + 1);

  // Stripe supports custom future cancellation dates. We deliberately use
  // the end of the NEXT billing period here: the current renewal is still
  // collected, then the subscription ends after that paid period.
  // The update is made without proration because the service is not being
  // shortened; the requested cancellation date is the next period end.
  await stripe.subscriptions.update(contract.stripe_subscription_id, {
    cancel_at: Math.floor(nextPeriodEnd.getTime() / 1000),
    proration_behavior: "none",
  });

  const { data, error } = await supabase
    .from("maintenance_contracts")
    .update({
      cancel_at_period_end: true,
      cancel_requested_at: new Date().toISOString(),
      cancel_effective_at: nextPeriodEnd.toISOString().slice(0, 10),
      pending_plan_id: null,
      pending_change_effective_at: null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", contract.id)
    .eq("company_id", companyId)
    .select("*")
    .single();

  if (error) throw error;

  // Stripe now owns the future cancellation date, so no client-side or
  // cron-based cancellation is required for this case.
  return json({
    ok: true,
    scheduled: true,
    charged_next_period: true,
    cancel_effective_at: data.cancel_effective_at,
    stripe_subscription_status: "active",
  });
}

async function requestMaintenanceProjectChange(
  req: Request,
  body: Record<string, unknown>,
) {
  const { companyId } = await requireActiveUser(req);
  const contractId = String(body.contract_id || "").trim();
  const requestedProjectId = String(body.project_id || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(contractId)) {
    throw new HttpError(400, "contract_id no válido");
  }

  if (!/^[0-9a-f-]{36}$/i.test(requestedProjectId)) {
    throw new HttpError(400, "project_id no válido");
  }

  await getContractForCompany(contractId, companyId);

  const authenticatedSupabase = getAuthenticatedSupabaseClient(req);
  const { data, error } = await authenticatedSupabase.rpc(
    "request_maintenance_contract_project_change",
    {
      p_contract_id: contractId,
      p_requested_project_id: requestedProjectId,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] project change request failed", {
      contract_id: contractId,
      requested_project_id: requestedProjectId,
      company_id: companyId,
      error,
    });

    const message =
      error.message || "No se pudo registrar la solicitud de cambio de proyecto.";

    if (/rate.?limit|l[ií]mite|demasiad|too many/i.test(message)) {
      throw new HttpError(429, message);
    }

    throw new HttpError(409, message);
  }

  return json({ ok: true, request: data });
}

async function approveMaintenanceProjectChange(
  req: Request,
  body: Record<string, unknown>,
) {
  const { worker } = await requireActiveWorker(req);
  const requestId = String(body.request_id || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(requestId)) {
    throw new HttpError(400, "request_id no válido");
  }

  const authenticatedSupabase = getAuthenticatedSupabaseClient(req);
  const { data, error } = await authenticatedSupabase.rpc(
    "approve_maintenance_contract_project_change",
    { p_request_id: requestId },
  );

  if (error) {
    console.error("[maintenance-stripe] project change approval failed", {
      request_id: requestId,
      worker_id: worker.id,
      error,
    });
    throw new HttpError(
      409,
      error.message || "No se pudo aprobar la solicitud de cambio de proyecto.",
    );
  }

  return json({ ok: true, request: data });
}

async function rejectMaintenanceProjectChange(
  req: Request,
  body: Record<string, unknown>,
) {
  const { worker } = await requireActiveWorker(req);
  const requestId = String(body.request_id || "").trim();
  const reason = String(body.reason || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(requestId)) {
    throw new HttpError(400, "request_id no válido");
  }

  if (!reason) {
    throw new HttpError(400, "Debes indicar el motivo del rechazo");
  }

  const authenticatedSupabase = getAuthenticatedSupabaseClient(req);
  const { data, error } = await authenticatedSupabase.rpc(
    "reject_maintenance_contract_project_change",
    {
      p_request_id: requestId,
      p_reason: reason,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] project change rejection failed", {
      request_id: requestId,
      worker_id: worker.id,
      error,
    });
    throw new HttpError(
      409,
      error.message || "No se pudo rechazar la solicitud de cambio de proyecto.",
    );
  }

  return json({ ok: true, request: data });
}

async function cancelMaintenanceProjectChange(
  req: Request,
  body: Record<string, unknown>,
) {
  const { user } = await requireActiveUser(req);
  const requestId = String(body.request_id || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(requestId)) {
    throw new HttpError(400, "request_id no válido");
  }

  const authenticatedSupabase = getAuthenticatedSupabaseClient(req);
  const { data, error } = await authenticatedSupabase.rpc(
    "cancel_maintenance_contract_project_change",
    { p_request_id: requestId },
  );

  if (error) {
    console.error("[maintenance-stripe] project change cancellation failed", {
      request_id: requestId,
      user_id: user.id,
      error,
    });
    throw new HttpError(
      409,
      error.message || "No se pudo cancelar la solicitud de cambio de proyecto.",
    );
  }

  return json({ ok: true, request: data });
}

async function requestPlanChange(req: Request, body: Record<string, unknown>) {
  const { companyId } = await requireActiveUser(req);
  const contractId = String(body.contract_id || "");
  const newPlanCode = String(body.plan_code || "").trim().toLowerCase();
  const contract = await getContractForCompany(contractId, companyId);
  const newPlan = await getPlanByCode(newPlanCode);

  if (newPlan.es_personalizado || !newPlan.stripe_price_id) {
    throw new HttpError(400, "El cambio solicitado requiere una contratación personalizada");
  }

  await assertPlanMatchesStripePrice(newPlan);

  if (!contract.stripe_subscription_id) {
    throw new HttpError(409, "El contrato no tiene una suscripción Stripe");
  }

  if (contract.cancel_at_period_end) {
    throw new HttpError(409, "No se puede cambiar de plan mientras existe una cancelación programada");
  }

  if (contract.stripe_price_id === newPlan.stripe_price_id) {
    throw new HttpError(400, "El contrato ya utiliza ese plan");
  }

  if (!contract.current_period_end) {
    throw new HttpError(409, "El contrato no tiene un periodo de facturación válido");
  }

  // 091: máximo 1 solicitud de cambio de plan por empresa cada 7 días.
  // Se consume después de validar el periodo y antes de modificar Stripe.
  await consumeMaintenanceChangeRateLimit(
    companyId,
    "maintenance_plan_change",
  );

  const changeBeforeCutoff = canCancelWithoutNextCharge(contract.current_period_end);
  const effectiveAt = changeBeforeCutoff
    ? contract.current_period_end
    : (() => {
        const d = new Date(contract.current_period_end);
        d.setUTCMonth(d.getUTCMonth() + 1);
        return d.toISOString().slice(0, 10);
      })();

  const subscription = await stripe.subscriptions.retrieve(contract.stripe_subscription_id);
  const currentItem = subscription.items.data[0];
  if (!currentItem) throw new HttpError(409, "La suscripción Stripe no tiene ningún elemento de precio");

  // Stripe Subscription Schedules are used so the current period is not
  // changed and the new plan starts exactly at a future billing boundary.
  // This also makes the change survive a function restart without needing
  // a local timer.
  let schedule: Stripe.SubscriptionSchedule;

  if (subscription.schedule) {
    const scheduleId = typeof subscription.schedule === "string"
      ? subscription.schedule
      : subscription.schedule.id;
    schedule = await stripe.subscriptionSchedules.retrieve(scheduleId);
  } else {
    schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscription.id,
      metadata: {
        modira_company_id: companyId,
        modira_contract_id: contract.id,
      },
    });
  }

  const currentPhase = schedule.phases.find((phase) =>
    phase.start_date <= Math.floor(Date.now() / 1000) &&
    phase.end_date > Math.floor(Date.now() / 1000)
  ) ?? schedule.phases[schedule.phases.length - 1];

  if (!currentPhase) {
    throw new HttpError(409, "No se pudo determinar la fase actual de la suscripción");
  }

  const currentStart = currentPhase.start_date;
  const currentEnd = currentPhase.end_date;

  const addOneCalendarMonth = (unixSeconds: number) => {
    const d = new Date(unixSeconds * 1000);
    d.setUTCMonth(d.getUTCMonth() + 1);
    return Math.floor(d.getTime() / 1000);
  };

  const currentItems = currentPhase.items.map((item) => ({
    price: typeof item.price === "string" ? item.price : item.price.id,
    quantity: item.quantity ?? 1,
  }));

  const newPlanItems = [{
    price: newPlan.stripe_price_id,
    quantity: 1,
  }];

  const phases: any[] = [
    {
      start_date: currentStart,
      end_date: currentEnd,
      items: currentItems,
      proration_behavior: "none",
    },
  ];

  if (changeBeforeCutoff) {
    phases.push({
      start_date: currentEnd,
      end_date: addOneCalendarMonth(currentEnd),
      items: newPlanItems,
      proration_behavior: "none",
    });
  } else {
    const delayedStart = currentEnd;
    const delayedEnd = addOneCalendarMonth(currentEnd);
    phases.push({
      start_date: delayedStart,
      end_date: delayedEnd,
      items: currentItems,
      proration_behavior: "none",
    });
    phases.push({
      start_date: delayedEnd,
      end_date: addOneCalendarMonth(delayedEnd),
      items: newPlanItems,
      proration_behavior: "none",
    });
  }

  await stripe.subscriptionSchedules.update(schedule.id, {
    end_behavior: "release",
    proration_behavior: "none",
    phases,
  });

  const { data, error } = await supabase
    .from("maintenance_contracts")
    .update({
      pending_plan_id: newPlan.id,
      pending_change_effective_at: effectiveAt,
      updated_at: new Date().toISOString(),
    })
    .eq("id", contract.id)
    .eq("company_id", companyId)
    .select("*")
    .single();

  if (error) throw error;

  return json({
    ok: true,
    scheduled: true,
    effective_at: effectiveAt,
    plan: newPlan.code,
    charged_current_period: true,
    pending_plan_id: data.pending_plan_id,
    stripe_subscription_schedule_id: schedule.id,
  });
}

async function getSubscriptionStatus(req: Request, body: Record<string, unknown>) {
  const { companyId } = await requireActiveUser(req);
  const contractId = String(body.contract_id || "");
  const contract = await getContractForCompany(contractId, companyId);

  if (!contract.stripe_subscription_id) {
    return json({ ok: true, contract, stripe: null });
  }

  const subscription = await stripe.subscriptions.retrieve(contract.stripe_subscription_id);

  return json({
    ok: true,
    contract,
    stripe: {
      id: subscription.id,
      status: subscription.status,
      cancel_at_period_end: subscription.cancel_at_period_end,
      cancel_at: subscription.cancel_at,
      current_period_start: subscription.items.data[0]?.current_period_start ?? null,
      current_period_end: subscription.items.data[0]?.current_period_end ?? null,
      customer: typeof subscription.customer === "string"
        ? subscription.customer
        : subscription.customer.id,
    },
  });
}

function modiraIssuerFiscalSnapshot() {
  const first = (...keys: string[]) => {
    for (const key of keys) {
      const value = Deno.env.get(key);
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return null;
  };

  return {
    legalName: first("MODIRA_INVOICE_ISSUER_LEGAL_NAME") || "Modira",
    taxId: first("MODIRA_INVOICE_ISSUER_TAX_ID") || "",
    address: first("MODIRA_INVOICE_ISSUER_ADDRESS"),
    postalCode: first("MODIRA_INVOICE_ISSUER_POSTAL_CODE"),
    city: first("MODIRA_INVOICE_ISSUER_CITY"),
    province: first("MODIRA_INVOICE_ISSUER_PROVINCE"),
    country: first("MODIRA_INVOICE_ISSUER_COUNTRY") || "ES",
  };
}

function pdfSafeText(value: unknown, fallback = ""): string {
  if (value === null || value === undefined) return fallback;
  return String(value).replace(/\r/g, "").trim();
}

function formatInvoicePdfAmount(value: unknown, currency = "EUR"): string {
  const amount = Number(value);
  if (!Number.isFinite(amount)) return `0,00 ${currency}`;
  return `${amount.toLocaleString("es-ES", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })} ${currency}`;
}

function formatInvoicePdfDate(value: unknown): string {
  const raw = pdfSafeText(value);
  if (!raw) return "—";

  const date = new Date(`${raw.slice(0, 10)}T00:00:00Z`);
  if (!Number.isFinite(date.getTime())) return raw.slice(0, 10);

  return date.toLocaleDateString("es-ES", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    timeZone: "UTC",
  });
}

function wrapPdfText(
  text: string,
  font: any,
  size: number,
  maxWidth: number,
): string[] {
  const normalized = pdfSafeText(text);
  if (!normalized) return [""];

  const lines: string[] = [];
  for (const paragraph of normalized.split("\n")) {
    const words = paragraph.split(/\s+/).filter(Boolean);
    if (!words.length) {
      lines.push("");
      continue;
    }

    let current = "";
    for (const word of words) {
      const candidate = current ? `${current} ${word}` : word;
      if (font.widthOfTextAtSize(candidate, size) <= maxWidth) {
        current = candidate;
        continue;
      }

      if (current) lines.push(current);

      // A single exceptionally long token is split so it cannot escape the page.
      if (font.widthOfTextAtSize(word, size) > maxWidth) {
        let fragment = "";
        for (const char of word) {
          const candidateFragment = fragment + char;
          if (
            fragment &&
            font.widthOfTextAtSize(candidateFragment, size) > maxWidth
          ) {
            lines.push(fragment);
            fragment = char;
          } else {
            fragment = candidateFragment;
          }
        }
        current = fragment;
      } else {
        current = word;
      }
    }

    if (current) lines.push(current);
  }

  return lines.length ? lines : [""];
}

async function generateMaintenanceInvoicePdf(
  invoice: Record<string, any>,
): Promise<Uint8Array> {
  const isRectification = Boolean(invoice.rectifies_invoice_id);
  let originalInvoiceNumber = "";

  if (isRectification) {
    const { data: original, error: originalError } = await supabase
      .from("maintenance_invoices")
      .select("id, serie, numero")
      .eq("id", invoice.rectifies_invoice_id)
      .maybeSingle();

    if (originalError) throw originalError;
    if (!original) {
      throw new Error("No se encuentra la factura original de la rectificativa");
    }

    originalInvoiceNumber = `${pdfSafeText(original.serie, "MNT")}-${pdfSafeText(original.numero)}`;
  }

  const pdf = await PDFDocument.create();

  pdf.setTitle(
    `${isRectification ? "Factura rectificativa" : "Factura"} ${pdfSafeText(invoice.serie, "MNT")}-${pdfSafeText(invoice.numero)}`,
  );
  pdf.setAuthor("Modira");
  pdf.setSubject(isRectification ? "Factura rectificativa de mantenimiento" : "Factura de mantenimiento");
  pdf.setCreator("Modira maintenance-stripe");
  pdf.setProducer("Modira");

  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);

  const PAGE_WIDTH = 595.28;
  const PAGE_HEIGHT = 841.89;
  const MARGIN = 42;
  const CONTENT_WIDTH = PAGE_WIDTH - MARGIN * 2;

  const ink = rgb(0.09, 0.11, 0.15);
  const muted = rgb(0.38, 0.41, 0.46);
  const line = rgb(0.82, 0.84, 0.88);
  const accent = rgb(0.06, 0.17, 0.40);
  const soft = rgb(0.95, 0.96, 0.98);
  const white = rgb(1, 1, 1);

  let page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;

  const newPage = () => {
    page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
    y = PAGE_HEIGHT - MARGIN;
  };

  const ensureSpace = (height: number) => {
    if (y - height < MARGIN) newPage();
  };

  const drawText = (
    value: unknown,
    x: number,
    topY: number,
    size = 10,
    font = regular,
    color = ink,
  ) => {
    page.drawText(pdfSafeText(value), {
      x,
      y: topY - size,
      size,
      font,
      color,
    });
  };

  const drawWrapped = (
    value: unknown,
    x: number,
    topY: number,
    width: number,
    size = 9,
    font = regular,
    color = ink,
    lineHeight = size + 3,
  ) => {
    const lines = wrapPdfText(pdfSafeText(value), font, size, width);
    lines.forEach((lineText, index) => {
      drawText(lineText, x, topY - index * lineHeight, size, font, color);
    });
    return lines.length * lineHeight;
  };

  const drawRule = (ruleY: number) => {
    page.drawLine({
      start: { x: MARGIN, y: ruleY },
      end: { x: PAGE_WIDTH - MARGIN, y: ruleY },
      thickness: 0.7,
      color: line,
    });
  };

  const drawSectionTitle = (title: string) => {
    ensureSpace(28);
    drawText(title, MARGIN, y, 11, bold, accent);
    y -= 18;
    drawRule(y);
    y -= 14;
  };

  // Para rectificativas se usan deliberadamente los datos provisionales
  // solicitados por Modira. Las facturas ordinarias conservan su configuración.
  const issuerName = isRectification
    ? "MODIRA"
    : pdfSafeText(invoice.issuer_legal_name) || modiraIssuerFiscalSnapshot().legalName;
  const issuerTaxId = isRectification
    ? "999999"
    : pdfSafeText(invoice.issuer_tax_id) || modiraIssuerFiscalSnapshot().taxId;
  const issuerAddress = isRectification
    ? "A DETERMINAR"
    : pdfSafeText(invoice.issuer_address) || modiraIssuerFiscalSnapshot().address || "";
  const issuerPostal = isRectification
    ? ""
    : pdfSafeText(invoice.issuer_postal_code) || modiraIssuerFiscalSnapshot().postalCode || "";
  const issuerCity = isRectification
    ? ""
    : pdfSafeText(invoice.issuer_city) || modiraIssuerFiscalSnapshot().city || "";
  const issuerProvince = isRectification
    ? ""
    : pdfSafeText(invoice.issuer_province) || modiraIssuerFiscalSnapshot().province || "";
  const issuerCountry = isRectification
    ? "ES"
    : pdfSafeText(invoice.issuer_country) || modiraIssuerFiscalSnapshot().country || "ES";

  // Header
  drawText("MODIRA", MARGIN, y, 25, bold, accent);
  drawText(
    isRectification ? "FACTURA RECTIFICATIVA DE MANTENIMIENTO" : "FACTURA DE MANTENIMIENTO",
    MARGIN,
    y - 31,
    11,
    bold,
    muted,
  );

  const invoiceNumber = `${pdfSafeText(invoice.serie, "MNT")}-${pdfSafeText(invoice.numero)}`;
  const headerRightX = PAGE_WIDTH - MARGIN - 190;
  drawText(isRectification ? "Nº DE RECTIFICATIVA" : "Nº DE FACTURA", headerRightX, y, 8, bold, muted);
  drawText(invoiceNumber, headerRightX, y - 14, 16, bold, ink);
  drawText("FECHA DE EMISIÓN", headerRightX, y - 39, 8, bold, muted);
  drawText(formatInvoicePdfDate(invoice.fecha_emision), headerRightX, y - 53, 10, regular, ink);

  if (isRectification) {
    drawText("RECTIFICA A", headerRightX, y - 69, 8, bold, muted);
    drawText(originalInvoiceNumber, headerRightX, y - 82, 10, bold, ink);
    y -= 108;
  } else {
    y -= 88;
  }
  drawRule(y);
  y -= 20;

  // Issuer / customer
  const columnGap = 24;
  const columnWidth = (CONTENT_WIDTH - columnGap) / 2;
  const rightColumnX = MARGIN + columnWidth + columnGap;

  drawText("EMISOR", MARGIN, y, 8, bold, muted);
  drawText("CLIENTE", rightColumnX, y, 8, bold, muted);
  y -= 16;

  const issuerLines = [
    issuerName,
    issuerTaxId ? `NIF/CIF/VAT: ${issuerTaxId}` : "",
    issuerAddress,
    [issuerPostal, issuerCity].filter(Boolean).join(" "),
    issuerProvince,
    issuerCountry,
  ].filter(Boolean);

  const customerLines = [
    pdfSafeText(invoice.customer_legal_name),
    invoice.customer_tax_id
      ? `NIF/CIF/VAT: ${pdfSafeText(invoice.customer_tax_id)}`
      : "",
    pdfSafeText(invoice.customer_address),
    [pdfSafeText(invoice.customer_postal_code), pdfSafeText(invoice.customer_city)]
      .filter(Boolean)
      .join(" "),
    pdfSafeText(invoice.customer_province),
    pdfSafeText(invoice.customer_country, "ES"),
  ].filter(Boolean);

  const maxPartyLines = Math.max(issuerLines.length, customerLines.length);
  for (let i = 0; i < maxPartyLines; i++) {
    drawText(issuerLines[i] || "", MARGIN, y - i * 14, 9, i === 0 ? bold : regular, ink);
    drawText(
      customerLines[i] || "",
      rightColumnX,
      y - i * 14,
      9,
      i === 0 ? bold : regular,
      ink,
    );
  }

  y -= Math.max(issuerLines.length, customerLines.length) * 14 + 18;

  if (isRectification) {
    drawSectionTitle("MOTIVO DE RECTIFICACIÓN");
    const reasonHeight = drawWrapped(
      invoice.rectification_reason,
      MARGIN,
      y,
      CONTENT_WIDTH,
      9,
      regular,
      ink,
    );
    y -= reasonHeight + 12;
  }

  // Period / operation
  drawSectionTitle("PERIODO DE MANTENIMIENTO");

  const periodLabel =
    `${formatInvoicePdfDate(invoice.periodo_inicio)} — ${formatInvoicePdfDate(invoice.periodo_fin)}`;

  drawText("Periodo facturado", MARGIN, y, 8, bold, muted);
  drawText(periodLabel, MARGIN, y - 14, 10, regular, ink);

  drawText("Fecha de operación", rightColumnX, y, 8, bold, muted);
  drawText(formatInvoicePdfDate(invoice.fecha_operacion), rightColumnX, y - 14, 10, regular, ink);

  y -= 43;

  // Service
  drawSectionTitle("CONCEPTO");

  page.drawRectangle({
    x: MARGIN,
    y: y - 34,
    width: CONTENT_WIDTH,
    height: 34,
    color: soft,
    borderColor: line,
    borderWidth: 0.5,
  });

  drawText("SERVICIO", MARGIN + 10, y - 9, 8, bold, muted);
  drawText("IMPORTE", PAGE_WIDTH - MARGIN - 90, y - 9, 8, bold, muted);

  const snapshotDescription =
    pdfSafeText(invoice.contract_snapshot?.descripcion) ||
    pdfSafeText(invoice.contract_snapshot?.quoted_description);

  const serviceDescription = [
    pdfSafeText(invoice.descripcion) ||
      `Plan de mantenimiento ${pdfSafeText(invoice.contract_snapshot?.nombre, "")}`.trim(),
    snapshotDescription &&
      snapshotDescription !== pdfSafeText(invoice.descripcion)
      ? snapshotDescription
      : "",
  ]
    .filter(Boolean)
    .join("\n");

  y -= 52;

  const serviceHeight = drawWrapped(
    serviceDescription,
    MARGIN + 10,
    y,
    CONTENT_WIDTH - 120,
    9,
    regular,
    ink,
  );

  const currency = pdfSafeText(invoice.moneda, "EUR").toUpperCase();
  const subtotalText = formatInvoicePdfAmount(invoice.subtotal, currency);

  drawText(
    subtotalText,
    PAGE_WIDTH - MARGIN - 90,
    y,
    9,
    regular,
    ink,
  );

  y -= Math.max(18, serviceHeight) + 14;

  const snapshot = asRecord(invoice.contract_snapshot);
  const planName =
    pdfSafeText(snapshot.nombre) ||
    pdfSafeText(snapshot.plan_name) ||
    pdfSafeText(invoice.descripcion).replace(/^Plan de mantenimiento\s*/i, "").trim();

  if (planName) {
    drawText("Plan contratado", MARGIN + 10, y, 8, bold, muted);
    drawText(planName, MARGIN + 105, y, 9, regular, ink);
    y -= 17;
  }

  // Totals
  drawSectionTitle("RESUMEN ECONÓMICO");

  const summaryX = PAGE_WIDTH - MARGIN - 205;
  const summaryValueX = PAGE_WIDTH - MARGIN - 5;

  const drawSummaryRow = (
    label: string,
    value: string,
    isTotal = false,
  ) => {
    ensureSpace(22);
    drawText(label, summaryX, y, isTotal ? 10 : 9, isTotal ? bold : regular, isTotal ? ink : muted);
    const width = (isTotal ? bold : regular).widthOfTextAtSize(value, isTotal ? 11 : 9);
    page.drawText(value, {
      x: summaryValueX - width,
      y: y - (isTotal ? 11 : 9),
      size: isTotal ? 11 : 9,
      font: isTotal ? bold : regular,
      color: ink,
    });
    y -= isTotal ? 22 : 19;
  };

  drawSummaryRow("Base imponible", formatInvoicePdfAmount(invoice.subtotal, currency));

  if (invoice.iva_aplicado) {
    drawSummaryRow(
      `IVA (${Number(invoice.iva_porcentaje || 0).toLocaleString("es-ES", {
        maximumFractionDigits: 4,
      })}%)`,
      formatInvoicePdfAmount(invoice.iva_importe, currency),
    );
  } else {
    drawSummaryRow("IVA", "0,00 " + currency);
  }

  if (invoice.irpf_aplicado) {
    drawSummaryRow(
      `IRPF (${Number(invoice.irpf_porcentaje || 0).toLocaleString("es-ES", {
        maximumFractionDigits: 4,
      })}%)`,
      `-${formatInvoicePdfAmount(invoice.irpf_importe, currency)}`,
    );
  }

  y -= 3;
  page.drawRectangle({
    x: summaryX - 8,
    y: y - 30,
    width: PAGE_WIDTH - MARGIN - summaryX + 8,
    height: 34,
    color: accent,
  });

  drawText("IMPORTE A PAGAR", summaryX + 2, y - 9, 9, bold, white);

  const totalText = formatInvoicePdfAmount(invoice.importe_a_pagar, currency);
  const totalWidth = bold.widthOfTextAtSize(totalText, 13);
  page.drawText(totalText, {
    x: summaryValueX - totalWidth,
    y: y - 12 - 13,
    size: 13,
    font: bold,
    color: white,
  });

  y -= 52;

  // Due date and Stripe reference
  ensureSpace(55);
  drawText("VENCIMIENTO", MARGIN, y, 8, bold, muted);
  drawText(formatInvoicePdfDate(invoice.fecha_vencimiento), MARGIN, y - 14, 10, regular, ink);

  if (invoice.stripe_invoice_id) {
    drawText("REFERENCIA STRIPE", rightColumnX, y, 8, bold, muted);
    drawText(pdfSafeText(invoice.stripe_invoice_id), rightColumnX, y - 14, 8, regular, muted);
  }

  y -= 44;

  // Footer
  drawRule(MARGIN + 24);
  drawText(
    `Factura generada automáticamente por Modira · ${issuerName}`,
    MARGIN,
    MARGIN + 15,
    7.5,
    regular,
    muted,
  );
  drawText(
    `Documento oficial · SHA-256 registrado en el sistema`,
    PAGE_WIDTH - MARGIN - 190,
    MARGIN + 15,
    7.5,
    regular,
    muted,
  );

  return new Uint8Array(await pdf.save());
}

async function finalizeMaintenanceInvoiceBackendDocument(
  invoiceId: string,
  pdf: Uint8Array,
): Promise<Record<string, any> | null> {
  const { data: invoice, error: invoiceError } = await supabase
    .from("maintenance_invoices")
    .select("id, serie, numero, document_path, document_sha256")
    .eq("id", invoiceId)
    .single();

  if (invoiceError) throw invoiceError;
  if (!invoice) throw new Error("Factura de mantenimiento no encontrada");

  if (invoice.document_path) {
    const existing = await supabase.storage
      .from("maintenance-invoices")
      .download(invoice.document_path);

    if (!existing.error && existing.data) {
      const existingBytes = new Uint8Array(
        await existing.data.arrayBuffer(),
      );

      const existingHash = await sha256Hex(existingBytes);

      if (
        invoice.document_sha256 &&
        String(invoice.document_sha256).toLowerCase() !== existingHash
      ) {
        throw new Error(
          "El SHA-256 almacenado del PDF oficial no coincide con el archivo de Storage",
        );
      }

      return invoice;
    }

    throw new Error(
      "La factura ya tiene document_path, pero no se ha podido recuperar el PDF oficial",
    );
  }

  const path =
    `${invoice.id}/factura-${pdfSafeText(invoice.serie, "MNT")}-${pdfSafeText(invoice.numero)}.pdf`;

  if (
    path.includes("..") ||
    path.startsWith("/") ||
    !path.toLowerCase().endsWith(".pdf")
  ) {
    throw new Error(
      "La ruta generada para el PDF de la factura no es válida",
    );
  }

  const upload = await supabase.storage
    .from("maintenance-invoices")
    .upload(path, pdf, {
      contentType: "application/pdf",
      cacheControl: "private, max-age=31536000",
      upsert: false,
    });

  if (upload.error) {
    // El PDF puede haber sido subido correctamente en un intento anterior,
    // pero la asociación documental con la factura pudo fallar después.
    // En ese caso reutilizamos el objeto existente en Storage.
    const reread = await supabase
      .from("maintenance_invoices")
      .select("id, serie, numero, document_path, document_sha256")
      .eq("id", invoiceId)
      .single();

    if (reread.error) throw reread.error;

    if (reread.data?.document_path) {
      return reread.data;
    }

    const existing = await supabase.storage
      .from("maintenance-invoices")
      .download(path);

    if (!existing.error && existing.data) {
      const existingBytes = new Uint8Array(
        await existing.data.arrayBuffer(),
      );

      // Usamos el SHA real del PDF que ya existe en Storage.
      // No lo comparamos con el PDF recién generado, ya que el objeto
      // existente puede proceder de un intento anterior.
      const existingHash = await sha256Hex(existingBytes);

      if (existingBytes.byteLength === 0) {
        throw new Error(
          "El PDF existente para esta factura está vacío",
        );
      }

      if (existingBytes.byteLength > 20 * 1024 * 1024) {
        throw new Error(
          "El PDF existente para esta factura supera el tamaño máximo permitido",
        );
      }

      const existingSignature = new TextDecoder().decode(
        existingBytes.slice(0, 5),
      );

      if (existingSignature !== "%PDF-") {
        throw new Error(
          "El documento existente para esta factura no es un PDF válido",
        );
      }

      const { data, error } = await supabase.rpc(
        "finalize_maintenance_invoice_backend_document",
        {
          p_invoice_id: invoiceId,
          p_document_path: path,
          p_document_sha256: existingHash,
        },
      );

      if (error) {
        console.error(
          "[maintenance-stripe] existing maintenance invoice PDF finalization failed",
          {
            invoice_id: invoiceId,
            document_path: path,
            error,
          },
        );

        throw error;
      }

      return (data || null) as Record<string, any> | null;
    }

    throw upload.error;
  }

  const pdfSha256 = await sha256Hex(pdf);

  const { data, error } = await supabase.rpc(
    "finalize_maintenance_invoice_backend_document",
    {
      p_invoice_id: invoiceId,
      p_document_path: path,
      p_document_sha256: pdfSha256,
    },
  );

  if (error) {
    console.error(
      "[maintenance-stripe] maintenance invoice backend document finalization failed",
      {
        invoice_id: invoiceId,
        document_path: path,
        error,
      },
    );

    // The object remains in the private bucket and can be finalized safely on
    // the next Stripe retry/reconciliation. Do not create another object.
    throw error;
  }

  return (data || null) as Record<string, any> | null;
}

async function ensureMaintenanceInvoiceOfficialDocument(
  invoiceId: string,
): Promise<void> {
  const { data: invoice, error } = await supabase
    .from("maintenance_invoices")
    .select("*")
    .eq("id", invoiceId)
    .single();

  if (error) throw error;
  if (!invoice) throw new Error("Factura de mantenimiento no encontrada");

  if (invoice.document_path) {
    const existing = await supabase.storage
      .from("maintenance-invoices")
      .download(invoice.document_path);

    if (!existing.error && existing.data) {
      const existingBytes = new Uint8Array(await existing.data.arrayBuffer());
      const existingHash = await sha256Hex(existingBytes);

      if (
        invoice.document_sha256 &&
        String(invoice.document_sha256).toLowerCase() === existingHash
      ) {
        return;
      }
    }

    throw new Error(
      "La factura tiene un documento oficial asociado, pero su integridad no se ha podido verificar",
    );
  }

  const pdf = await generateMaintenanceInvoicePdf(invoice);

  if (pdf.byteLength <= 0) {
    throw new Error("El PDF oficial generado está vacío");
  }

  if (pdf.byteLength > 20 * 1024 * 1024) {
    throw new Error("El PDF oficial generado supera el límite de 20 MiB");
  }

  const signature = new TextDecoder().decode(pdf.slice(0, 5));
  if (signature !== "%PDF-") {
    throw new Error("El generador de facturas no ha producido un PDF válido");
  }

  await finalizeMaintenanceInvoiceBackendDocument(invoiceId, pdf);
}

async function createMaintenanceInvoiceRectification(
  req: Request,
  body: Record<string, unknown>,
) {
  await requireActiveWorker(req);
  // Both domains are required: invoice permission alone would also authorize
  // Accounting, which may read maintenance but must not create maintenance invoices.
  await requireWorkerPermission(req, "maintenance.create");
  await requireWorkerPermission(req, "invoices.create");

  const originalInvoiceId = String(
    body.original_invoice_id ?? body.invoice_id ?? "",
  ).trim();
  if (!/^[0-9a-f-]{36}$/i.test(originalInvoiceId)) {
    throw new HttpError(400, "original_invoice_id no válido");
  }

  const reason = String(body.rectification_reason ?? body.reason ?? "").trim();
  if (!reason || reason.length > 2000) {
    throw new HttpError(400, "El motivo de rectificación es obligatorio y no puede superar 2000 caracteres");
  }

  const customerDataSource = String(
    body.rectification_customer_data_source ?? body.customer_data_source ?? "original_invoice",
  ).trim();
  if (!['original_invoice', 'current_company'].includes(customerDataSource)) {
    throw new HttpError(400, "rectification_customer_data_source debe ser original_invoice o current_company");
  }

  const { data: original, error: originalError } = await supabase
    .from("maintenance_invoices")
    .select("*")
    .eq("id", originalInvoiceId)
    .maybeSingle();

  if (originalError) throw originalError;
  if (!original) throw new HttpError(404, "Factura de mantenimiento original no encontrada");
  if (original.estado === "borrador") {
    throw new HttpError(409, "No se puede rectificar una factura que todavía está en borrador");
  }
  if (!original.company_id) {
    throw new HttpError(409, "La factura original no tiene una empresa asociada");
  }
  if (!original.periodo_inicio || !original.periodo_fin) {
    throw new HttpError(409, "La factura original no tiene un periodo de mantenimiento válido");
  }
  if (!original.document_path || !original.document_sha256) {
    throw new HttpError(409, "La factura original debe tener un PDF oficial y su SHA-256 antes de rectificarse");
  }

  // Antes de emitir una rectificativa, verificamos el documento oficial real
  // de la factura original. No se modifica ni se vuelve a generar el original.
  const originalExpectedPrefix = `${original.id}/`;
  if (
    !String(original.document_path).startsWith(originalExpectedPrefix) ||
    String(original.document_path).includes("..") ||
    !String(original.document_path).toLowerCase().endsWith(".pdf")
  ) {
    throw new HttpError(409, "La ruta del PDF oficial de la factura original no es válida");
  }

  const originalPdfDownload = await supabase.storage
    .from("maintenance-invoices")
    .download(original.document_path);
  if (originalPdfDownload.error || !originalPdfDownload.data) {
    throw new HttpError(409, "No se ha podido comprobar el PDF oficial de la factura original");
  }

  const originalPdfBytes = new Uint8Array(await originalPdfDownload.data.arrayBuffer());
  if (new TextDecoder().decode(originalPdfBytes.slice(0, 5)) !== "%PDF-") {
    throw new HttpError(409, "El documento oficial de la factura original no es un PDF válido");
  }
  const actualOriginalHash = await sha256Hex(originalPdfBytes);
  if (actualOriginalHash !== String(original.document_sha256).toLowerCase()) {
    throw new HttpError(409, "El SHA-256 del PDF original no coincide; no se puede emitir la rectificativa");
  }

  const readMoney = (provided: unknown, fallback: unknown, label: string): number => {
    const raw = provided === undefined || provided === null || provided === ""
      ? Number(fallback ?? 0)
      : Number(provided);
    if (!Number.isFinite(raw) || raw < 0 || raw > 9999999999.99) {
      throw new HttpError(400, `${label} debe ser un importe válido no negativo`);
    }
    return Math.round((raw + Number.EPSILON) * 100) / 100;
  };

  const readBoolean = (provided: unknown, fallback: unknown, label: string): boolean => {
    if (provided === undefined || provided === null) return Boolean(fallback);
    if (typeof provided !== "boolean") {
      throw new HttpError(400, `${label} debe ser true o false`);
    }
    return provided;
  };

  const readPercent = (provided: unknown, fallback: unknown, label: string): number => {
    const raw = provided === undefined || provided === null || provided === ""
      ? Number(fallback ?? 0)
      : Number(provided);
    if (!Number.isFinite(raw) || raw < 0 || raw > 100) {
      throw new HttpError(400, `${label} debe estar entre 0 y 100`);
    }
    return Math.round((raw + Number.EPSILON) * 100) / 100;
  };

  const subtotal = readMoney(body.subtotal, original.subtotal, "subtotal");
  const ivaAplicado = readBoolean(body.iva_aplicado, original.iva_aplicado, "iva_aplicado");
  const ivaPorcentaje = ivaAplicado
    ? readPercent(body.iva_porcentaje, original.iva_porcentaje, "iva_porcentaje")
    : 0;
  const irpfAplicado = readBoolean(body.irpf_aplicado, original.irpf_aplicado, "irpf_aplicado");
  const irpfPorcentaje = irpfAplicado
    ? readPercent(body.irpf_porcentaje, original.irpf_porcentaje, "irpf_porcentaje")
    : 0;

  let customerSnapshot = {
    customer_legal_name: original.customer_legal_name,
    customer_tax_id: original.customer_tax_id,
    customer_address: original.customer_address,
    customer_postal_code: original.customer_postal_code,
    customer_city: original.customer_city,
    customer_province: original.customer_province,
    customer_country: original.customer_country || "ES",
  };

  if (customerDataSource === "current_company") {
    const { data: company, error: companyError } = await supabase
      .from("companies")
      .select("*")
      .eq("id", original.company_id)
      .maybeSingle();

    if (companyError) throw companyError;
    if (!company) throw new HttpError(404, "No se encuentra la empresa de la factura original");

    const fiscal = companyFiscalSnapshot(asRecord(company));
    const missing = [
      !fiscal.legalName && "razón social",
      !fiscal.taxId && "NIF/CIF/VAT",
      !fiscal.address && "dirección fiscal",
      !fiscal.postalCode && "código postal",
      !fiscal.city && "ciudad",
      !fiscal.country && "país",
    ].filter(Boolean);
    if (missing.length) {
      throw new HttpError(409, `La empresa no tiene los datos fiscales actuales completos. Falta: ${missing.join(", ")}`);
    }

    customerSnapshot = {
      customer_legal_name: fiscal.legalName!,
      customer_tax_id: fiscal.taxId!,
      customer_address: fiscal.address!,
      customer_postal_code: fiscal.postalCode!,
      customer_city: fiscal.city!,
      customer_province: fiscal.province,
      customer_country: fiscal.country || "ES",
    };
  }

  const today = new Date().toISOString().slice(0, 10);
  const issuerSnapshot = {
    issuer_legal_name: "MODIRA",
    issuer_tax_id: "999999",
    issuer_address: "A DETERMINAR",
    issuer_postal_code: null,
    issuer_city: null,
    issuer_province: null,
    issuer_country: "ES",
  };

  // Se genera una fila nueva con serie propia. Los importes se recalculan en
  // PostgreSQL mediante maintenance_invoices_calculate_totals; no confiamos
  // en montos ni totales enviados por el navegador.
  const { data: inserted, error: insertError } = await supabase
    .from("maintenance_invoices")
    .insert({
      maintenance_contract_id: original.maintenance_contract_id,
      company_id: original.company_id,
      user_id: original.user_id,
      project_id: original.project_id,
      serie: "MNT-R",
      estado: "pendiente",
      fecha_emision: today,
      fecha_operacion: original.fecha_operacion || today,
      fecha_vencimiento: original.fecha_vencimiento || null,
      fecha_pago: null,
      periodo_inicio: original.periodo_inicio,
      periodo_fin: original.periodo_fin,
      descripcion: String(body.descripcion ?? `Rectificativa de factura ${original.serie}-${original.numero}`).trim().slice(0, 2000),
      contract_snapshot: original.contract_snapshot,
      subtotal,
      iva_aplicado: ivaAplicado,
      iva_porcentaje: ivaPorcentaje,
      irpf_aplicado: irpfAplicado,
      irpf_porcentaje: irpfPorcentaje,
      moneda: original.moneda || "EUR",
      ...customerSnapshot,
      ...issuerSnapshot,
      rectifies_invoice_id: original.id,
      rectification_reason: reason,
      rectification_customer_data_source: customerDataSource,
      stripe_invoice_id: null,
      stripe_customer_id: original.stripe_customer_id || null,
      electronic_format: null,
      electronic_document_storage_path: null,
      electronic_document_hash: null,
      pdf_storage_path: null,
      pdf_sha256: null,
      document_path: null,
      document_sha256: null,
      document_mime_type: null,
      document_file_size: null,
      document_uploaded_at: null,
      document_uploaded_by: null,
      stripe_pdf_storage_path: null,
      stripe_pdf_sha256: null,
    })
    .select("*")
    .single();

  if (insertError) {
    console.error("[maintenance-stripe] maintenance rectification insert failed", {
      original_invoice_id: original.id,
      customer_data_source: customerDataSource,
      error: insertError,
    });
    throw new HttpError(409, "No se ha podido crear la factura rectificativa. Comprueba los datos fiscales y los importes.");
  }

  try {
    const pdf = await generateMaintenanceInvoicePdf(inserted);
    if (pdf.byteLength <= 0 || pdf.byteLength > 20 * 1024 * 1024) {
      throw new Error("El PDF rectificativo está vacío o supera el límite de 20 MiB");
    }
    if (new TextDecoder().decode(pdf.slice(0, 5)) !== "%PDF-") {
      throw new Error("El generador no ha producido un PDF válido");
    }

    await finalizeMaintenanceInvoiceBackendDocument(inserted.id, pdf);

    const { data: completed, error: completedError } = await supabase
      .from("maintenance_invoices")
      .select("*")
      .eq("id", inserted.id)
      .single();
    if (completedError) throw completedError;

    console.info("[maintenance-stripe] maintenance rectification created", {
      invoice_id: inserted.id,
      original_invoice_id: original.id,
      series: completed.serie,
      number: completed.numero,
      customer_data_source: customerDataSource,
    });

    return json({ ok: true, invoice: completed, original_invoice_id: original.id });
  } catch (error) {
    console.error("[maintenance-stripe] rectification created but PDF finalization failed", {
      invoice_id: inserted.id,
      original_invoice_id: original.id,
      error,
    });
    throw new HttpError(
      500,
      `La rectificativa ${inserted.serie}-${inserted.numero} se creó, pero no se pudo finalizar su PDF. Conserva el ID ${inserted.id} para recuperar el documento.`,
    );
  }
}

async function ensureMaintenanceRectificationDocument(
  req: Request,
  body: Record<string, unknown>,
) {
  await requireActiveWorker(req);
  // Recovery changes a maintenance invoice document; require both permissions
  // so invoice-only roles cannot manage maintenance documents.
  await requireWorkerPermission(req, "maintenance.update");
  await requireWorkerPermission(req, "invoices.update");

  const invoiceId = String(body.invoice_id ?? "").trim();
  if (!/^[0-9a-f-]{36}$/i.test(invoiceId)) {
    throw new HttpError(400, "invoice_id no válido");
  }

  const { data: invoice, error } = await supabase
    .from("maintenance_invoices")
    .select("id, rectifies_invoice_id, document_path, document_sha256, serie, numero")
    .eq("id", invoiceId)
    .maybeSingle();

  if (error) throw error;
  if (!invoice) throw new HttpError(404, "Factura de mantenimiento no encontrada");
  if (!invoice.rectifies_invoice_id) {
    throw new HttpError(409, "Esta acción solo recupera documentos de facturas rectificativas");
  }

  await ensureMaintenanceInvoiceOfficialDocument(invoiceId);

  const { data: refreshed, error: refreshError } = await supabase
    .from("maintenance_invoices")
    .select("*")
    .eq("id", invoiceId)
    .single();
  if (refreshError) throw refreshError;

  return json({ ok: true, invoice: refreshed });
}

async function getCurrentMaintenanceContractProjectId(
  contractId: string,
): Promise<string | null> {
  const { data, error } = await supabase
    .from("maintenance_contract_projects")
    .select("project_id")
    .eq("maintenance_contract_id", contractId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  return data?.project_id ?? null;
}

async function applyMaintenanceProjectChangeForInvoicePeriod(
  contract: Record<string, any>,
  periodStart: string,
): Promise<{
  contract: Record<string, any>;
  projectId: string;
  applied: boolean;
}> {
  let currentContract = contract;

  const pendingProjectId = currentContract.pending_project_id as string | null;
  const pendingEffectiveAt =
    currentContract.pending_project_change_effective_at as string | null;

  if (pendingProjectId && pendingEffectiveAt && periodStart >= pendingEffectiveAt) {
    const { data: appliedRequest, error } = await supabase.rpc(
      "apply_maintenance_contract_project_change",
      { p_contract_id: currentContract.id },
    );

    if (error) {
      console.error("[maintenance-stripe] project change application failed", {
        contract_id: currentContract.id,
        period_start: periodStart,
        pending_project_id: pendingProjectId,
        pending_effective_at: pendingEffectiveAt,
        error,
      });
      throw error;
    }

    const { data: refreshedContract, error: refreshedError } = await supabase
      .from("maintenance_contracts")
      .select("*")
      .eq("id", currentContract.id)
      .single();

    if (refreshedError) throw refreshedError;

    currentContract = refreshedContract;

    const projectId = await getCurrentMaintenanceContractProjectId(
      currentContract.id,
    );

    if (!projectId) {
      throw new Error(
        "El contrato de mantenimiento no tiene un proyecto asociado después de aplicar el cambio.",
      );
    }

    console.info(
      "[maintenance-stripe] maintenance project change applied for invoice period",
      {
        contract_id: currentContract.id,
        period_start: periodStart,
        request_id: appliedRequest?.id ?? null,
        project_id: projectId,
      },
    );

    return { contract: currentContract, projectId, applied: true };
  }

  // Un webhook retrasado de un periodo anterior no debe aplicar todavía
  // el cambio futuro ni modificar retroactivamente la factura histórica.
  const projectId = await getCurrentMaintenanceContractProjectId(
    currentContract.id,
  );

  if (!projectId) {
    throw new Error("El contrato de mantenimiento no tiene un proyecto asociado.");
  }

  return { contract: currentContract, projectId, applied: false };
}

async function createMaintenanceInvoiceFromStripeInvoice(
  invoice: Stripe.Invoice,
  subscription: Stripe.Subscription | null,
  allowContractCreation = false,
) {
  const subscriptionId = getInvoiceSubscriptionId(invoice);

  if (!subscriptionId) return;

  let resolvedContract = await getContractBySubscription(subscriptionId);

  if (!resolvedContract && subscription && allowContractCreation) {
    resolvedContract = await createOrGetContractFromSubscription(subscription, true);
  }

  if (!resolvedContract) return;

  const invoiceRecord = stripeInvoiceRecord(invoice);

  // Para las facturas de suscripción, la fuente de verdad del período
  // facturado es el período actual del Subscription Item. El objeto Invoice
  // puede no reflejar correctamente el ciclo mensual esperado en todos los
  // eventos/versiones de la API de Stripe.
  const subscriptionItem = subscription?.items?.data?.[0];
  const subscriptionPeriodStart = subscriptionItem?.current_period_start ?? null;
  const subscriptionPeriodEnd = subscriptionItem?.current_period_end ?? null;

  const periodStart = subscriptionPeriodStart
    ? isoDateFromUnix(subscriptionPeriodStart)
    : invoiceRecord.period_start
      ? isoDateFromUnix(invoiceRecord.period_start)
      : resolvedContract.current_period_start;
  const periodEnd = subscriptionPeriodEnd
    ? isoDateFromUnix(subscriptionPeriodEnd)
    : invoiceRecord.period_end
      ? isoDateFromUnix(invoiceRecord.period_end)
      : resolvedContract.current_period_end;

  if (!periodStart || !periodEnd) {
    throw new Error("La factura Stripe no contiene un periodo de facturación válido");
  }

  // La comprobación fiscal se hace antes de crear/actualizar el registro
  // local de la factura. La fuente de verdad es companies; las solicitudes
  // fiscales pendientes todavía no cuentan.
  const company = await getCompany(resolvedContract.company_id);
  assertCurrentFiscalData(company);
  const fiscal = companyFiscalSnapshot(company);
  const issuer = modiraIssuerFiscalSnapshot();

  // Sincronizamos ahora las fechas del contrato con Stripe. No modificamos
  // aquí los campos pending_project_* del workflow de Modira.
  if (subscription) {
    const syncedContract = await updateContractBySubscription(subscription);
    if (syncedContract) {
      resolvedContract = syncedContract;
    }
  }

  // 091: resolvemos el proyecto respecto al periodo facturado y aplicamos
  // el cambio aprobado justo al alcanzar su fecha efectiva.
  const projectResolution = await applyMaintenanceProjectChangeForInvoicePeriod(
    resolvedContract as Record<string, any>,
    periodStart,
  );
  resolvedContract = projectResolution.contract;
  const invoiceProjectId = projectResolution.projectId;

  const existing = await supabase
    .from("maintenance_invoices")
    .select("id, document_path, document_sha256")
    .eq("stripe_invoice_id", getInvoiceId(invoice))
    .maybeSingle();

  if (existing.error) throw existing.error;

  if (existing.data) {
    await ensureMaintenanceInvoiceOfficialDocument(existing.data.id);
    await storeStripeInvoiceDocument(invoice, existing.data.id);
    return;
  }

const stripeTotal =
  (invoiceRecord.total ?? invoiceRecord.amount_due ?? 0) / 100;

const contractIvaAplicado =
  resolvedContract.iva_aplicado !== false;

const contractIvaPorcentaje = Number(
  resolvedContract.iva_porcentaje ?? 21,
);

const subtotal = contractIvaAplicado &&
  contractIvaPorcentaje > 0
    ? Number(
        (
          stripeTotal /
          (1 + contractIvaPorcentaje / 100)
        ).toFixed(2),
      )
    : Number(stripeTotal.toFixed(2));
      const totalTax = getInvoiceTaxAmounts(invoice).reduce(
    (sum, tax) => sum + (tax.amount || 0),
    0,
  ) / 100;


const effectiveTaxRate =
  contractIvaAplicado && totalTax > 0
    ? Number(
        (
          (totalTax / Math.max(
            Number(invoiceRecord.subtotal ?? 0) / 100,
            0.01,
          )) * 100
        ).toFixed(4),
      )
    : 0;

if (contractIvaAplicado) {
  const ivaDifference = Math.abs(
    effectiveTaxRate - contractIvaPorcentaje,
  );

  if (ivaDifference > 0.05) {
    console.error(
      "[maintenance-stripe] contract IVA does not match Stripe tax",
      {
        contract_id: resolvedContract.id,
        contract_iva: contractIvaPorcentaje,
        stripe_iva: effectiveTaxRate,
        stripe_invoice_id: getInvoiceId(invoice),
      },
    );

    throw new Error(
      "El IVA de Stripe no coincide con el IVA configurado en el contrato de mantenimiento",
    );
  }
}


  const invoiceRow = await supabase
    .from("maintenance_invoices")
    .insert({
      maintenance_contract_id: resolvedContract.id,
      company_id: resolvedContract.company_id,
      user_id: resolvedContract.user_id,
      project_id: invoiceProjectId,
      serie: "MNT",
      estado: invoiceRecord.status === "paid" ? "pagada" : "pendiente",
      fecha_emision: isoDateFromUnix(invoiceRecord.created) || new Date().toISOString().slice(0, 10),
      fecha_operacion: periodStart,
      fecha_vencimiento: invoiceRecord.due_date
        ? isoDateFromUnix(invoiceRecord.due_date)
        : periodEnd,
      fecha_pago: invoiceRecord.status_transitions?.paid_at
        ? isoDateFromUnix(invoiceRecord.status_transitions.paid_at)
        : null,
      periodo_inicio: periodStart,
      periodo_fin: periodEnd,
      descripcion: `Plan de mantenimiento ${resolvedContract.nombre_plan}`,
      contract_snapshot: resolvedContract.plan_snapshot,
      subtotal,
      iva_aplicado: contractIvaAplicado,
iva_porcentaje: contractIvaAplicado
  ? contractIvaPorcentaje
  : 0,
      irpf_aplicado: false,
      irpf_porcentaje: 0,
      customer_legal_name: fiscal.legalName,
      customer_tax_id: fiscal.taxId,
      customer_address: fiscal.address,
      customer_postal_code: fiscal.postalCode,
      customer_city: fiscal.city,
      customer_province: fiscal.province,
      customer_country: fiscal.country,
      issuer_legal_name: issuer.legalName,
      issuer_tax_id: issuer.taxId,
      issuer_address: issuer.address,
      issuer_postal_code: issuer.postalCode,
      issuer_city: issuer.city,
      issuer_province: issuer.province,
      issuer_country: issuer.country,
      stripe_invoice_id: getInvoiceId(invoice),
      stripe_customer_id: typeof invoiceRecord.customer === "string"
        ? invoiceRecord.customer
        : invoiceRecord.customer?.id ?? null,
    })
    .select("*")
    .single();

  let localInvoiceId = invoiceRow.data?.id as string | undefined;

  if (invoiceRow.error) {
    const reread = await supabase
      .from("maintenance_invoices")
      .select("*")
      .eq("stripe_invoice_id", getInvoiceId(invoice))
      .maybeSingle();

    if (!reread.data) throw invoiceRow.error;
    localInvoiceId = reread.data.id;
  }

  if (localInvoiceId) {
    const local = await supabase
      .from("maintenance_invoices")
      .select("importe_a_pagar, moneda")
      .eq("id", localInvoiceId)
      .single();

    if (local.error) throw local.error;

    const stripeTotal = (invoiceRecord.total ?? invoiceRecord.amount_due ?? 0) / 100;
    const localTotal = Number(local.data.importe_a_pagar);

    if (Math.abs(localTotal - stripeTotal) > 0.01) {
      console.error("[maintenance-stripe] local invoice total does not match Stripe", {
        invoice_id: getInvoiceId(invoice),
        local_total: localTotal,
        stripe_total: stripeTotal,
      });
      throw new Error("El importe calculado de la factura de mantenimiento no coincide con Stripe");
    }

    // The local invoice is now the source of truth. Generate the official
    // Modira document from the immutable fiscal/economic snapshot and only
    // then store Stripe's own PDF as an auxiliary document.
    await ensureMaintenanceInvoiceOfficialDocument(localInvoiceId);
    await storeStripeInvoiceDocument(invoice, localInvoiceId);
  }
}


async function storeStripeInvoiceDocument(invoice: Stripe.Invoice, localInvoiceId: string) {
  const invoiceRecord = stripeInvoiceRecord(invoice);
  if (!invoiceRecord.invoice_pdf) return;

  try {
    const response = await fetch(invoiceRecord.invoice_pdf);
    if (!response.ok) {
      console.error("[maintenance-stripe] could not download Stripe invoice PDF", response.status);
      return;
    }

    const pdf = new Uint8Array(await response.arrayBuffer());
    const path = `${localInvoiceId}/stripe-invoice-${getInvoiceId(invoice)}.pdf`;

    const upload = await supabase.storage
      .from("maintenance-invoices")
      .upload(path, pdf, {
        contentType: "application/pdf",
        upsert: true,
      });

    if (upload.error) throw upload.error;

    const pdfSha256 = await sha256Hex(pdf);

    await supabase
      .from("maintenance_invoices")
      .update({
        // 050 separa expresamente el PDF de Stripe del PDF de Modira.
        stripe_pdf_storage_path: path,
        stripe_pdf_sha256: pdfSha256,
        // Compatibilidad con los campos legacy de 049.
        pdf_storage_path: path,
        pdf_sha256: pdfSha256,
        updated_at: new Date().toISOString(),
      })
      .eq("id", localInvoiceId);
  } catch (error) {
    // Document delivery must not cause a duplicate payment if the PDF host
    // is temporarily unavailable. The invoice remains stored and the next
    // reconciliation can attach the document.
    console.error("[maintenance-stripe] invoice PDF storage failed", error);
  }
}

async function sha256Hex(data: Uint8Array): Promise<string> {
  const bytes = new Uint8Array(data);
  const digest = await crypto.subtle.digest("SHA-256", bytes);

  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function registerMaintenancePayment(invoice: Stripe.Invoice) {
  const invoiceRecord = stripeInvoiceRecord(invoice);
  const stripeInvoiceId = getInvoiceId(invoice);

  const localInvoiceQuery = await supabase
    .from("maintenance_invoices")
    .select("*")
    .eq("stripe_invoice_id", stripeInvoiceId)
    .maybeSingle();

  if (localInvoiceQuery.error) throw localInvoiceQuery.error;
  const localInvoice = localInvoiceQuery.data;
  if (!localInvoice) return;

  const paymentIntentId = getInvoicePaymentIntentId(invoice);

  if (!paymentIntentId) return;

  const amount = invoiceRecord.amount_paid ?? invoiceRecord.amount_due ?? 0;
  const currency = (invoiceRecord.currency || localInvoice.moneda || "eur").toUpperCase();

  const expectedAmount = Math.round(Number(localInvoice.importe_a_pagar) * 100);
  if (amount !== expectedAmount) {
    throw new Error(
      `El importe recibido de Stripe (${amount}) no coincide con el importe exigible (${expectedAmount})`,
    );
  }

  if (currency !== String(localInvoice.moneda || "EUR").toUpperCase()) {
    throw new Error("La moneda del pago Stripe no coincide con la moneda de la factura");
  }

  const existing = await supabase
    .from("payments")
    .select("id")
    .eq("stripe_payment_intent_id", paymentIntentId)
    .maybeSingle();

  if (existing.error) throw existing.error;

  if (existing.data) {
    await supabase
      .from("maintenance_invoices")
      .update({
        estado: "pagada",
        fecha_pago: localInvoice.fecha_pago || new Date().toISOString().slice(0, 10),
        updated_at: new Date().toISOString(),
      })
      .eq("id", localInvoice.id);
    return;
  }

  const paymentInsert = await supabase
    .from("payments")
    .insert({
      company_id: localInvoice.company_id,
      user_id: localInvoice.user_id,
      invoice_id: null,
      maintenance_invoice_id: localInvoice.id,
      stripe_checkout_session_id: null,
      stripe_payment_intent_id: paymentIntentId,
      amount,
      currency,
      status: "succeeded",
      paid_at: invoiceRecord.status_transitions?.paid_at
        ? new Date(invoiceRecord.status_transitions.paid_at * 1000).toISOString()
        : new Date().toISOString(),
      description: localInvoice.descripcion,
    })
    .select("id")
    .single();

  if (paymentInsert.error) {
    const reread = await supabase
      .from("payments")
      .select("id")
      .eq("stripe_payment_intent_id", paymentIntentId)
      .maybeSingle();

    if (!reread.data) throw paymentInsert.error;
  }

  await supabase
    .from("maintenance_invoices")
    .update({
      estado: "pagada",
      fecha_pago: invoiceRecord.status_transitions?.paid_at
        ? new Date(invoiceRecord.status_transitions.paid_at * 1000).toISOString().slice(0, 10)
        : new Date().toISOString().slice(0, 10),
      updated_at: new Date().toISOString(),
    })
    .eq("id", localInvoice.id);
}

async function registerPaymentFailure(
  subscription: Stripe.Subscription,
  reason: string,
) {
  const { data, error } = await supabase.rpc(
    "register_maintenance_billing_failure",
    {
      p_subscription_id: subscription.id,
      p_reason: reason,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] could not register payment failure", error);
    throw error;
  }

  return data as Record<string, any> | null;
}

async function resetPaymentFailures(subscriptionId: string) {
  const { data, error } = await supabase.rpc(
    "reset_maintenance_billing_failures",
    {
      p_subscription_id: subscriptionId,
    },
  );

  if (error) {
    console.error("[maintenance-stripe] could not reset payment failures", error);
    throw error;
  }

  return data as Record<string, any> | null;
}

async function pauseSubscriptionForPaymentFailure(
  subscription: Stripe.Subscription,
  failureCount: number,
) {
  if (failureCount < MAX_CONSECUTIVE_PAYMENT_FAILURES) return;

  try {
    await stripe.subscriptions.update(subscription.id, {
      pause_collection: { behavior: "keep_as_draft" },
    });
  } catch (error) {
    console.error(
      "[maintenance-stripe] could not pause subscription after repeated payment failures",
      error,
    );
    throw error;
  }

  const { error } = await supabase
    .from("maintenance_contracts")
    .update({
      estado: "pausado",
      updated_at: new Date().toISOString(),
    })
    .eq("stripe_subscription_id", subscription.id);

  if (error) throw error;
}

async function handleInvoicePaid(invoice: Stripe.Invoice) {
  const subscriptionId = getInvoiceSubscriptionId(invoice);
  const subscription = subscriptionId
    ? await stripe.subscriptions.retrieve(subscriptionId)
    : null;

  await createMaintenanceInvoiceFromStripeInvoice(invoice, subscription, true);
  await registerMaintenancePayment(invoice);

  if (!subscriptionId || !subscription) return;

  const contractBeforeReset = await getContractBySubscription(subscriptionId);
  await resetPaymentFailures(subscriptionId);

  // A successful payment clears a Modira payment-failure block. It does
  // not override a fiscal-data pause: that pause remains until the company
  // fiscal data is valid and the explicit resume action is executed.
  const companyId = subscription.metadata?.modira_company_id;
  if (!companyId) return;

  const company = await getCompany(companyId);
  const fiscalOk = missingFiscalFields(company).length === 0;
  const wasPaymentBlocked =
    Number(contractBeforeReset?.billing_failure_count ?? 0) >= MAX_CONSECUTIVE_PAYMENT_FAILURES &&
    String(contractBeforeReset?.billing_block_reason ?? "").startsWith("payment_failed");

  if (wasPaymentBlocked && fiscalOk && subscription.status !== "canceled") {
    try {
      await stripe.subscriptions.update(subscription.id, {
        pause_collection: null,
      });
    } catch (error) {
      console.error(
        "[maintenance-stripe] could not resume collection after successful payment",
        error,
      );
      throw error;
    }
  }

  await handleSubscriptionUpdated(
    await stripe.subscriptions.retrieve(subscription.id),
  );
}

async function handleSubscriptionUpdated(subscription: Stripe.Subscription) {
  const existing = await getContractBySubscription(subscription.id);
  if (!existing) return;

  const item = subscription.items.data[0];
  const priceId = typeof item?.price === "string" ? item.price : item?.price.id;

  let currentPlan: Record<string, unknown> | null = null;
  if (priceId) {
    const planQuery = await supabase
      .from("maintenance_plans")
      .select("*")
      .eq("stripe_price_id", priceId)
      .maybeSingle();

    if (planQuery.error) throw planQuery.error;
    currentPlan = planQuery.data as Record<string, unknown> | null;

    if (currentPlan) {
      try {
        await assertPlanMatchesStripePrice(currentPlan as Record<string, any>);
      } catch (error) {
        console.error("[maintenance-stripe] subscription price integrity failure", error);
        try {
          await stripe.subscriptions.update(subscription.id, {
            pause_collection: { behavior: "keep_as_draft" },
          });
        } catch (pauseError) {
          console.error("[maintenance-stripe] could not pause invalid price subscription", pauseError);
        }
        throw error;
      }
    }
  }

  const updates: Record<string, unknown> = {
    stripe_customer_id: typeof subscription.customer === "string"
      ? subscription.customer
      : subscription.customer.id,
    stripe_subscription_item_id: item?.id ?? null,
    stripe_price_id: priceId ?? null,
    current_period_start: isoDateFromUnix(item?.current_period_start ?? subscription.start_date ?? subscription.created),
    current_period_end: isoDateFromUnix(item?.current_period_end ?? null),
    renewal_day: getRenewalDayFromPeriodStart(item?.current_period_start ?? subscription.start_date ?? subscription.created),
    cancel_at_period_end: subscription.cancel_at_period_end,
    cancel_effective_at: subscription.cancel_at_period_end
      ? isoDateFromUnix(subscription.cancel_at ?? item?.current_period_end ?? null)
      : null,
    updated_at: new Date().toISOString(),
  };

  if (currentPlan) {
    updates.plan_id = currentPlan.id;
    updates.nombre_plan = currentPlan.nombre;
    updates.descripcion = currentPlan.descripcion;
    updates.precio = currentPlan.precio ?? 0;
    updates.moneda = currentPlan.moneda;
    updates.periodicidad = currentPlan.periodicidad;
    updates.pending_plan_id = null;
    updates.pending_change_effective_at = null;
    updates.plan_snapshot = {
      code: currentPlan.code,
      nombre: currentPlan.nombre,
      descripcion: currentPlan.descripcion,
      precio_catalogo: currentPlan.precio,
      moneda: currentPlan.moneda,
      periodicidad: currentPlan.periodicidad,
      captured_at: new Date().toISOString(),
    };
  }

  const localState = getSubscriptionLocalState(subscription);

  if (localState) {
    updates.estado = localState;
  }

  if (
    subscription.status === "canceled" ||
    subscription.status === "incomplete_expired"
  ) {
    updates.fecha_fin = isoDateFromUnix(
      subscription.ended_at ?? subscription.canceled_at ?? null,
    );
  }

  const { error } = await supabase
    .from("maintenance_contracts")
    .update(updates)
    .eq("stripe_subscription_id", subscription.id);

  if (error) throw error;
}

async function handleSubscriptionDeleted(subscription: Stripe.Subscription) {
  const { error } = await supabase
    .from("maintenance_contracts")
    .update({
      estado: "cancelado",
      fecha_fin: isoDateFromUnix(subscription.ended_at ?? subscription.canceled_at ?? null),
      cancel_at_period_end: false,
      cancel_effective_at: isoDateFromUnix(subscription.ended_at ?? subscription.canceled_at ?? null),
      updated_at: new Date().toISOString(),
    })
    .eq("stripe_subscription_id", subscription.id);

  if (error) throw error;
}

async function handleInvoicePaymentFailed(invoice: Stripe.Invoice) {
  const subscriptionId = getInvoiceSubscriptionId(invoice);

  if (!subscriptionId) return;

  const subscription = await stripe.subscriptions.retrieve(subscriptionId);

  // A failed collection attempt is still subject to the fiscal guard. If
  // fiscal data is incomplete, billing is paused for the fiscal reason and
  // we do not create an incomplete local fiscal invoice.
  const fiscalOk = await validateInvoiceFiscalState(invoice, subscription);
  if (!fiscalOk) return;

  await createMaintenanceInvoiceFromStripeInvoice(invoice, subscription);

  const local = await supabase
    .from("maintenance_invoices")
    .update({
      estado: "impagada",
      updated_at: new Date().toISOString(),
    })
    .eq("stripe_invoice_id", getInvoiceId(invoice));

  if (local.error) throw local.error;

  const invoiceRecord = stripeInvoiceRecord(invoice);
  const failureReason =
    typeof invoiceRecord.last_finalization_error?.message === "string"
      ? invoiceRecord.last_finalization_error.message
      : typeof invoiceRecord.description === "string"
        ? invoiceRecord.description
        : "Stripe ha rechazado o no ha podido completar el cobro.";

  const contract = await registerPaymentFailure(subscription, failureReason);
  const failureCount = Number(contract?.billing_failure_count ?? 0);

  if (failureCount >= MAX_CONSECUTIVE_PAYMENT_FAILURES) {
    await pauseSubscriptionForPaymentFailure(subscription, failureCount);
  } else {
    await handleSubscriptionUpdated(subscription);
  }
}

const STRIPE_WEBHOOK_PROCESSING_TIMEOUT_MS = 5 * 60 * 1000;
const STRIPE_WEBHOOK_ERROR_MAX_LENGTH = 4000;

function webhookErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message.slice(0, STRIPE_WEBHOOK_ERROR_MAX_LENGTH);
  try {
    return JSON.stringify(error).slice(0, STRIPE_WEBHOOK_ERROR_MAX_LENGTH);
  } catch {
    return String(error).slice(0, STRIPE_WEBHOOK_ERROR_MAX_LENGTH);
  }
}

async function claimStripeWebhookEvent(event: Stripe.Event): Promise<
  | { claimed: true }
  | { claimed: false; reason: "processed" | "processing" }
> {
  const now = new Date();

  const insert = await supabase
    .from("stripe_webhook_events")
    .insert({
      stripe_event_id: event.id,
      event_type: event.type,
      status: "processing",
      attempt_count: 1,
      processing_started_at: now.toISOString(),
      processed_at: null,
      last_error: null,
      updated_at: now.toISOString(),
    })
    .select("id")
    .maybeSingle();

  if (!insert.error) {
    return { claimed: true };
  }

  // The table has a UNIQUE constraint on stripe_event_id. Only that conflict
  // means that another invocation has already registered this event. Any
  // other database error must remain a real error and must not be interpreted
  // as a duplicate.
  if (insert.error.code !== "23505") {
    console.error("[maintenance-stripe] webhook event claim insert failed", insert.error);
    throw insert.error;
  }

  const { data: existing, error: readError } = await supabase
    .from("stripe_webhook_events")
    .select(
      "id, status, attempt_count, processing_started_at, processed_at, updated_at",
    )
    .eq("stripe_event_id", event.id)
    .maybeSingle();

  if (readError) {
    console.error("[maintenance-stripe] webhook event claim lookup failed", readError);
    throw readError;
  }

  if (!existing) {
    throw new Error(
      `No se pudo resolver la colisión del webhook Stripe ${event.id}`,
    );
  }

  if (existing.status === "processed") {
    return { claimed: false, reason: "processed" };
  }

  if (existing.status === "processing") {
    const startedAt = existing.processing_started_at
      ? new Date(existing.processing_started_at).getTime()
      : NaN;

    const isStale =
      !Number.isFinite(startedAt) ||
      Date.now() - startedAt >= STRIPE_WEBHOOK_PROCESSING_TIMEOUT_MS;

    if (!isStale) {
      return { claimed: false, reason: "processing" };
    }

    // A crashed/timed-out invocation can leave the row in processing forever.
    // Reclaim it only if the timestamp we read is still the same. This makes
    // two concurrent stale retries mutually exclusive.
    const nextAttempt = Number(existing.attempt_count || 0) + 1;
    const reclaim = await supabase
      .from("stripe_webhook_events")
      .update({
        status: "processing",
        attempt_count: nextAttempt,
        processing_started_at: now.toISOString(),
        processed_at: null,
        last_error: null,
        updated_at: now.toISOString(),
      })
      .eq("id", existing.id)
      .eq("status", "processing")
      .eq("processing_started_at", existing.processing_started_at)
      .select("id")
      .maybeSingle();

    if (!reclaim.error && reclaim.data) {
      return { claimed: true };
    }

    if (reclaim.error) {
      console.error("[maintenance-stripe] stale webhook claim failed", reclaim.error);
      throw reclaim.error;
    }

    // Another invocation reclaimed it first. Re-read so we never process the
    // same event concurrently after a stale claim race.
    const { data: reread, error: rereadError } = await supabase
      .from("stripe_webhook_events")
      .select("status, processing_started_at")
      .eq("id", existing.id)
      .maybeSingle();

    if (rereadError) throw rereadError;

    if (reread?.status === "processed") {
      return { claimed: false, reason: "processed" };
    }

    return { claimed: false, reason: "processing" };
  }

  if (existing.status === "failed") {
    // Failed events are deliberately retryable. Claim them again and keep the
    // same event row so the complete attempt history remains auditable.
    const nextAttempt = Number(existing.attempt_count || 0) + 1;
    const retry = await supabase
      .from("stripe_webhook_events")
      .update({
        status: "processing",
        attempt_count: nextAttempt,
        processing_started_at: now.toISOString(),
        processed_at: null,
        last_error: null,
        updated_at: now.toISOString(),
      })
      .eq("id", existing.id)
      .eq("status", "failed")
      .select("id")
      .maybeSingle();

    if (!retry.error && retry.data) {
      return { claimed: true };
    }

    if (retry.error) {
      console.error("[maintenance-stripe] failed webhook retry claim failed", retry.error);
      throw retry.error;
    }

    // Another retry won the race. Treat this delivery as an in-progress
    // duplicate and ask Stripe to retry rather than acknowledging it.
    return { claimed: false, reason: "processing" };
  }

  throw new Error(
    `Estado de webhook Stripe no reconocido para ${event.id}: ${String(existing.status)}`,
  );
}

async function markStripeWebhookEventProcessed(eventId: string) {
  const now = new Date().toISOString();

  const { data, error } = await supabase
    .from("stripe_webhook_events")
    .update({
      status: "processed",
      processed_at: now,
      processing_started_at: null,
      last_error: null,
      updated_at: now,
    })
    .eq("stripe_event_id", eventId)
    .eq("status", "processing")
    .select("id")
    .maybeSingle();

  if (error) {
    console.error("[maintenance-stripe] could not mark webhook as processed", {
      event_id: eventId,
      error,
    });
    throw error;
  }

  if (!data) {
    throw new Error(
      `No se pudo marcar como processed el webhook Stripe ${eventId}: no existe una fila en estado processing`,
    );
  }

  console.info("[maintenance-stripe] webhook marked as processed", {
    event_id: eventId,
  });
}

async function markStripeWebhookEventFailed(eventId: string, error: unknown) {
  const message = webhookErrorMessage(error);

  const { data, error: updateError } = await supabase
    .from("stripe_webhook_events")
    .update({
      status: "failed",
      processing_started_at: null,
      processed_at: null,
      last_error: message,
      updated_at: new Date().toISOString(),
    })
    .eq("stripe_event_id", eventId)
    .eq("status", "processing")
    .select("id")
    .maybeSingle();

  if (updateError) {
    console.error("[maintenance-stripe] could not mark webhook as failed", {
      event_id: eventId,
      error: updateError,
    });
  } else if (!data) {
    console.error(
      "[maintenance-stripe] webhook failure could not update its processing row",
      { event_id: eventId, message },
    );
  }
}

async function handleWebhook(req: Request) {
  const webhookSecret = requireEnv(
    MAINTENANCE_STRIPE_WEBHOOK_SECRET,
    "MAINTENANCE_STRIPE_WEBHOOK_SECRET",
  );
  const signature = req.headers.get("Stripe-Signature");
  if (!signature) return json({ error: "Missing Stripe-Signature" }, 400);

  const rawBody = await req.text();
  let event: Stripe.Event;

  try {
    event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      webhookSecret,
    );
  } catch (error) {
    console.error("[maintenance-stripe] invalid webhook signature", error);
    return json({ error: "Invalid webhook signature" }, 400);
  }

  const claim = await claimStripeWebhookEvent(event);

  if (claim.claimed === false) {
    if (claim.reason === "processed") {
      return json({ received: true, duplicate: true });
    }

    // Another invocation is actively processing this event. A 409 is
    // intentional: it tells Stripe not to consider this delivery successful,
    // so a later retry can take over if the active invocation fails.
    return json({ received: false, processing: true }, 409);
  }

  console.info("[maintenance-stripe] webhook processing started", {
    event_id: event.id,
    event_type: event.type,
  });

  try {
    switch (event.type) {
      case "invoice.created": {
        const invoice = event.data.object as Stripe.Invoice;
        const subscriptionId = getInvoiceSubscriptionId(invoice);
        const subscription = subscriptionId
          ? await stripe.subscriptions.retrieve(subscriptionId)
          : null;

        if (subscription) {
          const fiscalOk = await validateInvoiceFiscalState(invoice, subscription);
          if (!fiscalOk) break;
        }
        break;
      }

      case "invoice.finalized": {
        const invoice = event.data.object as Stripe.Invoice;
        const subscriptionId = getInvoiceSubscriptionId(invoice);
        const subscription = subscriptionId
          ? await stripe.subscriptions.retrieve(subscriptionId)
          : null;

        if (subscription) {
          const fiscalOk = await validateInvoiceFiscalState(invoice, subscription);
          if (!fiscalOk) break;
        }

        await createMaintenanceInvoiceFromStripeInvoice(invoice, subscription);
        break;
      }

      case "invoice.paid": {
        await handleInvoicePaid(event.data.object as Stripe.Invoice);
        break;
      }

      case "invoice.payment_failed": {
        await handleInvoicePaymentFailed(event.data.object as Stripe.Invoice);
        break;
      }

      case "invoice.payment_action_required": {
        const invoice = event.data.object as Stripe.Invoice;
        const subscriptionId = getInvoiceSubscriptionId(invoice);
        const subscription = subscriptionId
          ? await stripe.subscriptions.retrieve(subscriptionId)
          : null;

        if (subscription) {
          const fiscalOk = await validateInvoiceFiscalState(invoice, subscription);
          if (!fiscalOk) break;
        }

        await createMaintenanceInvoiceFromStripeInvoice(invoice, subscription);

        const { error: paymentActionUpdateError } = await supabase
          .from("maintenance_invoices")
          .update({
            estado: "impagada",
            updated_at: new Date().toISOString(),
          })
          .eq("stripe_invoice_id", getInvoiceId(invoice));

        if (paymentActionUpdateError) throw paymentActionUpdateError;

        break;
      }

      case "invoice.marked_uncollectible": {
        const invoice = event.data.object as Stripe.Invoice;
        await handleInvoicePaymentFailed(invoice);
        break;
      }

      case "invoice.voided": {
        const { error } = await supabase
          .from("maintenance_invoices")
          .update({ estado: "anulada", updated_at: new Date().toISOString() })
          .eq("stripe_invoice_id", (event.data.object as Stripe.Invoice).id);

        if (error) throw error;
        break;
      }

      case "customer.subscription.created": {
        // Fallback de seguridad: si checkout.session.completed se retrasa,
        // la propia suscripción ya contiene toda la metadata necesaria para
        // materializar el contrato. createOrGetContractFromSubscription()
        // es idempotente por stripe_subscription_id.
        const subscription = event.data.object as Stripe.Subscription;
        await createOrGetContractFromSubscription(subscription, true);
        break;
      }

      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const subscriptionId = typeof session.subscription === "string"
          ? session.subscription
          : session.subscription?.id;

        if (subscriptionId) {
          const subscription = await stripe.subscriptions.retrieve(subscriptionId);
          const contract = await createOrGetContractFromSubscription(subscription, true);

          const { error } = await supabase
            .from("maintenance_contracts")
            .update({
              stripe_checkout_session_id: session.id,
              contracted_at: new Date().toISOString(),
              terms_version: session.metadata?.modira_terms_version || MAINTENANCE_TERMS_VERSION,
              updated_at: new Date().toISOString(),
            })
            .eq("id", contract.id);

          if (error) throw error;
        }

        break;
      }

      case "customer.subscription.updated": {
        await handleSubscriptionUpdated(event.data.object as Stripe.Subscription);
        break;
      }

      case "customer.subscription.deleted": {
        await handleSubscriptionDeleted(event.data.object as Stripe.Subscription);
        break;
      }

      case "customer.subscription.paused": {
        await handleSubscriptionUpdated(event.data.object as Stripe.Subscription);
        break;
      }

      case "customer.subscription.resumed": {
        await handleSubscriptionUpdated(event.data.object as Stripe.Subscription);
        break;
      }

      default:
        // Event intentionally acknowledged. Unknown/unused Stripe event types
        // are still recorded as processed so Stripe does not redeliver them.
        break;
    }

    await markStripeWebhookEventProcessed(event.id);

    console.info("[maintenance-stripe] webhook processing completed", {
      event_id: event.id,
      event_type: event.type,
    });
  } catch (error) {
    console.error("[maintenance-stripe] webhook processing failed", {
      event_id: event.id,
      event_type: event.type,
      error,
    });

    // NEVER delete the event row here. Keeping status=failed makes the event
    // auditable and, more importantly, allows a future Stripe retry to reclaim
    // and process it. If the failure happened after a partial write, the
    // existing Stripe-ID uniqueness checks make the important side effects
    // idempotent.
    await markStripeWebhookEventFailed(event.id, error);

    return json({ error: "Webhook processing failed" }, 500);
  }

  return json({ received: true });
}

async function hashMaintenanceInvoiceDocument(
  req: Request,
  body: Record<string, unknown>,
) {
  await requireActiveWorker(req);
  const invoiceId = String(body.invoice_id || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(invoiceId)) {
    throw new HttpError(400, "invoice_id no válido");
  }

  const { data: maintenanceInvoice, error } = await supabase
    .from("maintenance_invoices")
    .select("id, document_path, document_sha256")
    .eq("id", invoiceId)
    .maybeSingle();

  if (error) throw error;
  if (!maintenanceInvoice) throw new HttpError(404, "Factura de mantenimiento no encontrada");
  if (!maintenanceInvoice.document_path) {
    throw new HttpError(409, "La factura todavía no tiene document_path asociado");
  }

  const expectedPrefix = `${maintenanceInvoice.id}/`;
  if (
    !maintenanceInvoice.document_path.startsWith(expectedPrefix) ||
    !maintenanceInvoice.document_path.toLowerCase().endsWith(".pdf")
  ) {
    throw new HttpError(409, "La ruta documental de la factura no es válida");
  }

  const download = await supabase.storage
    .from("maintenance-invoices")
    .download(maintenanceInvoice.document_path);

  if (download.error || !download.data) {
    console.error(
      "[maintenance-stripe] maintenance invoice PDF download failed",
      download.error,
    );
    throw new HttpError(409, "No se ha podido descargar el PDF real desde Storage");
  }

  const pdf = new Uint8Array(await download.data.arrayBuffer());
  const sha256 = await sha256Hex(pdf);

  if (
    maintenanceInvoice.document_sha256 &&
    String(maintenanceInvoice.document_sha256).toLowerCase() !== sha256
  ) {
    throw new HttpError(409, "El SHA-256 almacenado no coincide con el PDF actual. No se sobrescribe la huella existente.");
  }

  // 067 mantiene la RPC como única vía para fijar el hash. La RPC vuelve a
  // comprobar que el usuario es worker, que existe document_path y que una
  // huella existente no puede ser sustituida por otra diferente.
  const supabaseUser = getAuthenticatedSupabaseClient(req);
  const { data: updatedInvoice, error: hashError } = await supabaseUser.rpc(
    "set_maintenance_invoice_document_hash",
    {
      p_invoice_id: maintenanceInvoice.id,
      p_sha256: sha256,
    },
  );

  if (hashError) {
    console.error("[maintenance-stripe] maintenance invoice hash RPC failed", hashError);
    throw new HttpError(500, "No se ha podido registrar la huella digital del documento");
  }

  return json({
    ok: true,
    invoice_id: maintenanceInvoice.id,
    document_sha256: sha256,
    invoice: updatedInvoice,
  });
}


async function attachMaintenanceCustomProposalDocument(
  req: Request,
  body: Record<string, unknown>,
) {
  const { user, worker } = await requireActiveWorker(req);

  // This action calls a service_role-only RPC, so the authenticated worker
  // permission must be enforced here before crossing into service_role.
  // The RPC itself cannot evaluate the caller's worker RBAC context once
  // invoked through the service-role client.
  await requireWorkerPermission(req, "maintenance_proposals.update");

  const proposalId = String(body.proposal_id || "").trim();
  const documentPath = String(body.document_path || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(proposalId)) {
    throw new HttpError(400, "proposal_id no válido");
  }

  if (!documentPath) {
    throw new HttpError(400, "document_path es obligatorio");
  }

  // 074 only permits proposal documents under:
  //   <proposal_uuid>/<filename>.pdf
  // Never allow the client to make this Edge Function read another
  // proposal's folder or an arbitrary Storage path.
  const expectedPrefix = `${proposalId}/`;
  if (
    !documentPath.startsWith(expectedPrefix) ||
    documentPath.length <= expectedPrefix.length ||
    documentPath.includes("..") ||
    documentPath.startsWith("/") ||
    !documentPath.toLowerCase().endsWith(".pdf")
  ) {
    throw new HttpError(400, "La ruta del PDF de la propuesta no es válida");
  }

  const pathParts = documentPath.split("/");
  if (pathParts.length !== 2 || !pathParts[1]) {
    throw new HttpError(400, "La ruta del PDF de la propuesta no es válida");
  }

  // The Storage INSERT policy in migration 074 is the first security layer.
  // The Edge Function is the second one: it only accepts a PDF that already
  // exists in the private maintenance-proposals bucket.
  const { data: object, error: objectError } = await supabase.storage
    .from("maintenance-proposals")
    .download(documentPath);

  if (objectError || !object) {
    console.error("[maintenance-stripe] custom proposal PDF download failed", {
      proposal_id: proposalId,
      document_path: documentPath,
      error: objectError,
    });
    throw new HttpError(
      409,
      "No se ha podido descargar el PDF de la propuesta desde Storage",
    );
  }

  const pdf = new Uint8Array(await object.arrayBuffer());

  const MAX_PROPOSAL_PDF_BYTES = 20 * 1024 * 1024;
  if (pdf.byteLength <= 0) {
    throw new HttpError(409, "El PDF de la propuesta está vacío");
  }

  if (pdf.byteLength > MAX_PROPOSAL_PDF_BYTES) {
    throw new HttpError(413, "El PDF de la propuesta supera el límite de 20 MiB");
  }

  // Do not trust only the browser-provided MIME type. The object is already
  // constrained to application/pdf by the Storage policy, and we additionally
  // validate the PDF signature before registering the immutable hash.
  const pdfSignature = new TextDecoder().decode(pdf.slice(0, 5));
  if (pdfSignature !== "%PDF-") {
    throw new HttpError(409, "El archivo almacenado no es un PDF válido");
  }

  const sha256 = await sha256Hex(pdf);

  // 074 deliberately keeps this RPC service_role-only. The browser cannot
  // forge p_worker_id or directly create a document version/current_document_id.
  // The RPC itself re-validates:
  //   - active worker
  //   - proposal ownership/access
  //   - allowed proposal state
  //   - Storage object metadata
  //   - PDF size/type
  //   - rate limit
  //   - immutable document/version rules
  const { data: document, error: attachError } = await supabase.rpc(
    "attach_maintenance_custom_proposal_document",
    {
      p_proposal_id: proposalId,
      p_document_path: documentPath,
      p_document_sha256: sha256,
      p_worker_id: worker.id,
    },
  );

  if (attachError) {
    console.error(
      "[maintenance-stripe] custom proposal document attach RPC failed",
      {
        proposal_id: proposalId,
        document_path: documentPath,
        worker_id: worker.id,
        error: attachError,
      },
    );

    const message = attachError.message || "No se pudo registrar el documento de la propuesta";

    // Keep rate-limit failures explicit so the frontend can show the user
    // that the operation must wait rather than retrying aggressively.
    if (
      /rate.?limit|l[ií]mite|too many|demasiad/i.test(message)
    ) {
      throw new HttpError(429, message);
    }

    throw new HttpError(
      409,
      "No se pudo registrar el PDF de la propuesta",
    );
  }

  console.info("[maintenance-stripe] custom proposal document attached", {
    proposal_id: proposalId,
    document_path: documentPath,
    worker_id: worker.id,
    auth_user_id: user.id,
    sha256,
  });

  return json({
    ok: true,
    proposal_id: proposalId,
    document_path: documentPath,
    document_sha256: sha256,
    document,
  });
}

async function dispatchAuthenticated(req: Request, body: Record<string, unknown>) {
  const action = String(body.action || "").trim();

  switch (action) {
    case "create_checkout_session":
      return await createCheckoutSession(req, body);
    case "accept_custom_maintenance_proposal":
      return await acceptCustomMaintenanceProposal(req, body);
    case "request_cancellation":
      return await requestCancellation(req, body);
    case "request_plan_change":
      return await requestPlanChange(req, body);
    case "request_maintenance_project_change":
      return await requestMaintenanceProjectChange(req, body);
    case "approve_maintenance_project_change":
      return await approveMaintenanceProjectChange(req, body);
    case "reject_maintenance_project_change":
      return await rejectMaintenanceProjectChange(req, body);
    case "cancel_maintenance_project_change":
      return await cancelMaintenanceProjectChange(req, body);
    case "get_subscription_status":
      return await getSubscriptionStatus(req, body);
    case "resume_billing_after_fiscal_update":
      return await resumeBillingAfterFiscalUpdate(req, body);
    case "reconcile_subscription":
      return await reconcileSubscription(req, body);
    case "hash_maintenance_invoice_document":
      return await hashMaintenanceInvoiceDocument(req, body);
    case "create_maintenance_invoice_rectification":
      return await createMaintenanceInvoiceRectification(req, body);
    case "ensure_maintenance_rectification_document":
      return await ensureMaintenanceRectificationDocument(req, body);
    case "attach_maintenance_custom_proposal_document":
      return await attachMaintenanceCustomProposalDocument(req, body);
    default:
      throw new HttpError(400, "Acción de mantenimiento no soportada");
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: getCorsHeaders() });
  }

  if (req.method !== "POST") {
    return json({ error: "Method Not Allowed" }, 405);
  }

  try {
    // Stripe webhooks are distinguished by their signature and use the raw
    // request body. They do not carry a Supabase user JWT.
    if (req.headers.has("Stripe-Signature")) {
      return await handleWebhook(req);
    }

    const body = await req.json();
    return await dispatchAuthenticated(req, body);
  } catch (error) {
    if (error instanceof HttpError) {
      return json({ error: error.message }, error.status);
    }

    console.error("[maintenance-stripe] unhandled error", error);
    return json({ error: "Error interno del servidor" }, 500);
  }
});
