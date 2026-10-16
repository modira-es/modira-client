import { useEffect, useState } from "react";
import Header from "@/components/Header";
import { ArrowLeft, FileText } from "lucide-react";
import {
  getCurrentLegalDocument,
  type LegalDocument,
} from "@/lib/legalDocuments";
import LegalDocumentContent from "@/components/LegalDocumentContent";

export default function TermsAndConditions() {
  const [isScrolled, setIsScrolled] = useState(false);
  const [document, setDocument] = useState<LegalDocument | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let isMounted = true;

    async function loadTerms() {
      try {
        setIsLoading(true);
        setLoadError(null);
        const currentDocument = await getCurrentLegalDocument("terms_of_use");
        if (isMounted) setDocument(currentDocument);
      } catch (error) {
        console.error("No se han podido cargar los Términos y Condiciones:", error);
        if (isMounted) {
          setLoadError("No se han podido cargar los Términos y Condiciones. Inténtalo de nuevo más tarde.");
        }
      } finally {
        if (isMounted) setIsLoading(false);
      }
    }

    void loadTerms();
    return () => { isMounted = false; };
  }, []);

  useEffect(() => {
    const handleScroll = () => setIsScrolled(window.scrollY > 20);
    handleScroll();
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  const formattedDate = document?.effective_from
    ? new Date(document.effective_from).toLocaleDateString("es-ES", {
        day: "numeric", month: "long", year: "numeric",
      })
    : null;

  const goBack = () => {
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
  };

  return (
    <div className={`min-h-screen bg-[#F8FAFC] terms-page ${isScrolled ? "terms-scrolled" : "terms-top"}`}>
      <div className={`terms-header-wrapper ${isScrolled ? "terms-header-scrolled" : "terms-header-transparent"}`}>
        <Header />
      </div>

      <section className="pt-32 pb-14 md:pt-36 md:pb-16 bg-white border-b border-gray-100">
        <div className="container-lg mx-auto px-6 md:px-10 lg:px-12">
          <div className="max-w-5xl mx-auto">
            <button onClick={goBack} className="inline-flex items-center gap-2 text-sm font-medium text-[#1E3A8A] hover:text-[#16306F] transition-colors mb-8">
              <ArrowLeft size={18} /> Volver
            </button>
            <div className="max-w-4xl">
              <p className="text-sm font-semibold uppercase tracking-wider text-[#1E3A8A] mb-3">Área legal</p>
              <div className="flex items-start gap-4">
                <div className="hidden sm:flex flex-shrink-0 w-12 h-12 rounded-xl bg-[#EFF6FF] items-center justify-center mt-1">
                  <FileText size={24} className="text-[#1E3A8A]" />
                </div>
                <div>
                  <h1 className="text-4xl md:text-5xl font-bold tracking-tight text-[#1E3A8A] mb-5">
                    {document?.title ?? "Términos y Condiciones"}
                  </h1>
                  <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
                    Condiciones que regulan el acceso y utilización de MODIRA, así como las condiciones aplicables a la contratación y prestación de sus servicios.
                  </p>
                  <div className="mt-6 text-sm text-gray-400">
                    {document ? `Versión ${document.version} · Última actualización: ${formattedDate}` : isLoading ? "Cargando versión vigente…" : ""}
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
                <p className="text-xs font-semibold uppercase tracking-wider text-gray-400 mb-4">Documento</p>
                <p className="text-xs text-gray-500 leading-6">
                  {document ? `${document.title} · Versión ${document.version}` : "Documento legal vigente"}
                </p>
              </div>
            </aside>

            <div className="min-w-0">
              <article className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="px-6 py-8 md:px-10 md:py-12 lg:px-14">
                  <div className="pb-10 mb-10 border-b border-gray-100">
                    <p className="text-sm leading-7 text-gray-500">Este documento muestra la versión vigente de los Términos y Condiciones de MODIRA.</p>
                  </div>
                  {isLoading && <div className="py-12 text-center text-gray-500" role="status">Cargando Términos y Condiciones…</div>}
                  {!isLoading && loadError && <div className="rounded-xl border border-red-200 bg-red-50 p-6 text-red-700" role="alert">{loadError}</div>}
                  {!isLoading && !loadError && document && <LegalDocumentContent content={document.content} />}
                  {document && (
                    <div className="mt-16 pt-8 border-t border-gray-100">
                      <p className="text-sm text-gray-400 leading-6">Versión {document.version}{formattedDate ? ` · En vigor desde el ${formattedDate}` : ""}.</p>
                    </div>
                  )}
                </div>
              </article>
              <div className="mt-8 text-center">
                <button onClick={goBack} className="inline-flex items-center gap-2 text-sm font-medium text-[#1E3A8A] hover:text-[#16306F] transition-colors mb-8">
                  <ArrowLeft size={18} /> Volver
                </button>
              </div>
            </div>
          </div>
        </div>
      </main>

      <style>{`
        .terms-header-wrapper { position: relative; z-index: 50; min-height: 0; transition: background-color 250ms ease, box-shadow 250ms ease; }
        .terms-header-transparent { background: linear-gradient(to right, #102A66, #173B8F) !important; box-shadow: 0 4px 12px rgba(16, 42, 102, 0.18) !important; }
        .terms-header-transparent header { background: linear-gradient(to right, #102A66, #173B8F) !important; box-shadow: none !important; }
        .terms-header-scrolled { background-color: #ffffff !important; box-shadow: 0 1px 0 rgba(15, 23, 42, 0.06) !important; }
        .terms-header-scrolled header { background-color: #ffffff !important; box-shadow: none !important; }
        .terms-page { position: relative; }
      `}</style>
    </div>
  );
}
