import { supabase } from "@/lib/supabase";

export type LegalDocumentType =
  | "terms_of_use"
  | "privacy_information"
  | "audit_terms"
  | "cookie_policy"
  | "contract_terms";

export interface LegalDocument {
  id: string;
  document_type: LegalDocumentType;
  version: string;
  title: string;
  content: string;
  content_hash: string | null;
  effective_from: string;
}

export async function getCurrentLegalDocument(
  documentType: LegalDocumentType
): Promise<LegalDocument> {
  const now = new Date().toISOString();

  const { data, error } = await supabase
    .from("legal_documents")
    .select(
      "id, document_type, version, title, content, content_hash, effective_from"
    )
    .eq("document_type", documentType)
    .eq("is_current", true)
    .lte("effective_from", now)
    .or(`effective_until.is.null,effective_until.gt.${now}`)
    .order("effective_from", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    console.error(
      `Error al consultar el documento legal "${documentType}":`,
      error
    );

    throw new Error(
      "No se ha podido cargar el documento legal."
    );
  }

  if (!data) {
    throw new Error(
      `No existe una versión vigente del documento "${documentType}".`
    );
  }

  const document = data as unknown as LegalDocument;

  return document;
}