import { useEffect, useState } from "react";
import Header from "@/components/Header";
import { ArrowLeft, FileText } from "lucide-react";
import {
  getCurrentLegalDocument,
  type LegalDocument,
} from "@/lib/legalDocuments";
import LegalDocumentContent from "@/components/LegalDocumentContent";

export default function PrivacyPolicy() {
  const [isScrolled, setIsScrolled] = useState(false);
  const [document, setDocument] = useState<LegalDocument | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    const handleScroll = () => setIsScrolled(window.scrollY > 20);
    handleScroll();
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function loadDocument() {
      try {
        setIsLoading(true);
        setError(null);
        const currentDocument = await getCurrentLegalDocument("privacy_information");
        if (!cancelled) setDocument(currentDocument);
      } catch (err) {
        console.error("Error al cargar la Política de Privacidad:", err);
        if (!cancelled) {
          setError(
            err instanceof Error
              ? err.message
              : "No se ha podido cargar la Política de Privacidad."
          );
        }
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    }

    loadDocument();
    return () => {
      cancelled = true;
    };
  }, []);

  const effectiveDate = document?.effective_from
    ? new Intl.DateTimeFormat("es-ES", {
        day: "numeric",
        month: "long",
        year: "numeric",
      }).format(new Date(document.effective_from))
    : null;

  return (
    <div
      className={`min-h-screen bg-[#F8FAFC] privacy-page ${
        isScrolled ? "privacy-scrolled" : "privacy-top"
      }`}
    >
      <div
        className={`privacy-header-wrapper ${
          isScrolled ? "privacy-header-scrolled" : "privacy-header-transparent"
        }`}
      >
        <Header />
      </div>

      <section className="pt-32 pb-14 md:pt-36 md:pb-16 bg-white border-b border-gray-100">
        <div className="container-lg mx-auto px-6 md:px-10 lg:px-12">
          <div className="max-w-5xl mx-auto">
            <button
              onClick={() => {
                const previousPage = sessionStorage.getItem("modira_previous_page");
                if (previousPage) {
                  try {
                    const { url, scrollY } = JSON.parse(previousPage);
                    sessionStorage.setItem("modira_restore_scroll", String(scrollY));
                    window.location.href = url;
                  } catch {
                    window.location.href = "/";
                  }
                } else {
                  window.location.href = "/";
                }
              }}
              className="inline-flex items-center gap-2 text-sm font-medium text-[#1E3A8A] hover:text-[#16306F] transition-colors mb-8"
            >
              <ArrowLeft size={18} />
              Volver
            </button>

            <div className="max-w-4xl">
              <p className="text-sm font-semibold uppercase tracking-wider text-[#1E3A8A] mb-3">
                Área legal
              </p>
              <div className="flex items-start gap-4">
                <div className="hidden sm:flex flex-shrink-0 w-12 h-12 rounded-xl bg-[#EFF6FF] items-center justify-center mt-1">
                  <FileText size={24} className="text-[#1E3A8A]" />
                </div>
                <div>
                  <h1 className="text-4xl md:text-5xl font-bold tracking-tight text-[#1E3A8A] mb-5">
                    {document?.title ?? "Política de Privacidad"}
                  </h1>
                  <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
                    Información sobre cómo MODIRA trata, protege, conserva y gestiona los datos personales en relación con su sitio web, servicios, cuentas y funcionalidades.
                  </p>
                  <div className="mt-6 text-sm text-gray-400">
                    {document ? (
                      <>
                        Versión {document.version}
                        {effectiveDate ? ` · Entrada en vigor: ${effectiveDate}` : ""}
                      </>
                    ) : (
                      "Documento legal vigente"
                    )}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <main className="container-lg mx-auto px-6 md:px-10 lg:px-12 py-14 md:py-20">
        <div className="max-w-6xl mx-auto">
          <div className="grid lg:grid-cols-[240px_minmax(0,1fr)] gap-10 lg:gap-16">
            <aside className="hidden lg:block">
              <div className="sticky top-28">
                <p className="text-xs font-semibold uppercase tracking-wider text-gray-400 mb-4">
                  Documento
                </p>
                <div className="rounded-xl border border-gray-100 bg-white p-5">
                  <FileText size={22} className="text-[#1E3A8A] mb-3" />
                  <p className="text-sm font-semibold text-gray-700">
                    {document?.title ?? "Política de Privacidad"}
                  </p>
                  {document && (
                    <p className="text-xs text-gray-400 mt-2">Versión {document.version}</p>
                  )}
                </div>
              </div>
            </aside>

            <div className="min-w-0">
              <article className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="px-6 py-8 md:px-10 md:py-12 lg:px-14">
                  {isLoading ? (
                    <div className="py-12 text-center text-gray-500">
                      Cargando Política de Privacidad...
                    </div>
                  ) : error ? (
                    <div className="rounded-xl border border-red-100 bg-red-50 p-5 text-sm leading-7 text-red-700">
                      {error}
                    </div>
                  ) : document ? (
                    <>
                      <div className="pb-8 mb-8 border-b border-gray-100">
                        <p className="text-sm font-semibold text-[#1E3A8A] mb-2">
                          {document.title}
                        </p>
                        <p className="text-sm leading-7 text-gray-500">
                          Versión {document.version}
                          {effectiveDate ? ` · Entrada en vigor: ${effectiveDate}` : ""}
                        </p>
                      </div>
                      <LegalDocumentContent content={document.content} />
                      <div className="mt-16 pt-8 border-t border-gray-100">
                        <p className="text-sm text-gray-400 leading-6">
                          Documento legal vigente de MODIRA · Versión {document.version}
                        </p>
                      </div>
                    </>
                  ) : null}
                </div>
              </article>
            </div>
          </div>
        </div>
      </main>

      <style>{`
        .privacy-header-wrapper {
          position: relative;
          z-index: 50;
          min-height: 0;
          transition: background-color 250ms ease, box-shadow 250ms ease;
        }
        .privacy-header-transparent {
          background: linear-gradient(to right, #102A66, #173B8F) !important;
          box-shadow: 0 4px 12px rgba(16, 42, 102, 0.18) !important;
        }
        .privacy-header-transparent header {
          background: linear-gradient(to right, #102A66, #173B8F) !important;
          box-shadow: none !important;
        }
        .privacy-header-scrolled {
          background-color: #ffffff !important;
          box-shadow: 0 1px 0 rgba(15, 23, 42, 0.06) !important;
        }
        .privacy-header-scrolled header {
          background-color: #ffffff !important;
          box-shadow: none !important;
        }
        .privacy-page { position: relative; }
      `}</style>
    </div>
  );
}
