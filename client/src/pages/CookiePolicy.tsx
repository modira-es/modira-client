import { useEffect, useState } from "react";
import Header from "@/components/Header";
import { ArrowLeft, Cookie } from "lucide-react";
import {
  getCurrentLegalDocument,
  type LegalDocument,
} from "@/lib/legalDocuments";

function LegalText({ content }: { content: string }) {
  const normalizedContent = content
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .trim();

  const blocks = normalizedContent
    .split(/\n\s*\n/)
    .map((text) => text.trim())
    .filter(Boolean);

  return (
    <div className="space-y-6">
      {blocks.map((text, index) => {
        const isHeading =
          text.length < 180 &&
          !text.includes("\n") &&
          (/^\d+(?:\.\d+)*\.?\s+\S/.test(text) ||
            (text === text.toLocaleUpperCase("es-ES") && /[A-ZÁÉÍÓÚÜÑ]/.test(text)));

        const isLikelyListItem =
          !isHeading &&
          !text.includes("\n") &&
          (text.endsWith(";") || text.startsWith("• ") || text.startsWith("- "));

        if (isHeading) {
          return (
            <h2
              key={`${index}-${text}`}
              className="border-b border-gray-100 pb-3 pt-3 text-2xl font-bold leading-8 text-[#1E3A8A] md:text-3xl"
            >
              {text}
            </h2>
          );
        }

        if (isLikelyListItem) {
          return (
            <p
              key={`${index}-${text}`}
              className="pl-5 leading-8 text-gray-600"
            >
              {text.startsWith("• ") || text.startsWith("- ") ? text : `• ${text}`}
            </p>
          );
        }

        return (
          <p
            key={`${index}-${text}`}
            className="whitespace-pre-line leading-8 text-gray-600"
          >
            {text}
          </p>
        );
      })}
    </div>
  );
}

export default function CookiePolicy() {
  const [isScrolled, setIsScrolled] = useState(false);
  const [document, setDocument] = useState<LegalDocument | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let isMounted = true;

    async function loadCookiePolicy() {
      try {
        setIsLoading(true);
        setLoadError(null);
        const currentDocument = await getCurrentLegalDocument("cookie_policy");

        if (isMounted) {
          setDocument(currentDocument);
        }
      } catch (error) {
        console.error("No se ha podido cargar la Política de Cookies:", error);

        if (isMounted) {
          setLoadError(
            "No se ha podido cargar la Política de Cookies. Inténtalo de nuevo más tarde."
          );
        }
      } finally {
        if (isMounted) {
          setIsLoading(false);
        }
      }
    }

    void loadCookiePolicy();

    return () => {
      isMounted = false;
    };
  }, []);

  /*
   * ============================================================
   * MODIRA — COOKIE POLICY HEADER
   * ============================================================
   */

  useEffect(() => {
    const handleScroll = () => {
      setIsScrolled(window.scrollY > 20);
    };

    handleScroll();

    window.addEventListener("scroll", handleScroll, {
      passive: true,
    });

    return () => {
      window.removeEventListener("scroll", handleScroll);
    };
  }, []);

  return (
    <div
      className={`min-h-screen bg-[#F8FAFC] cookie-policy-page ${
        isScrolled
          ? "cookie-policy-scrolled"
          : "cookie-policy-top"
      }`}
    >
      {/* ========================================================
          HEADER
          ======================================================== */}

      <div
        className={`cookie-policy-header-wrapper ${
          isScrolled
            ? "cookie-policy-header-scrolled"
            : "cookie-policy-header-transparent"
        }`}
      >
        <Header />
      </div>

{/* ========================================================
    CABECERA DE LA PÁGINA
    ======================================================== */}

<section className="pt-32 pb-14 md:pt-36 md:pb-16 bg-white border-b border-gray-100">
  <div className="container-lg mx-auto px-6 md:px-10 lg:px-12">
    <div className="max-w-5xl mx-auto">
      <button
        onClick={() => window.history.back()}
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
            <Cookie
              size={24}
              className="text-[#1E3A8A]"
            />
          </div>

          <div>
            <h1 className="text-4xl md:text-5xl font-bold tracking-tight text-[#1E3A8A] mb-5">
              {document?.title ?? "Política de Cookies"}
            </h1>

            <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
              Información sobre las cookies y tecnologías similares
              utilizadas en la web de Modira, sus finalidades y la
              gestión de las preferencias del usuario.
            </p>

            <div className="mt-6 text-sm text-gray-400">
              {document
                ? `Versión ${document.version} · Última actualización: ${new Date(
                    document.effective_from
                  ).toLocaleDateString("es-ES", {
                    day: "numeric",
                    month: "long",
                    year: "numeric",
                  })}`
                : isLoading
                  ? "Cargando versión vigente…"
                  : ""}
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</section>

      {/* ========================================================
          CONTENIDO
          ======================================================== */}

      <main className="py-12 md:py-20">
        <div className="container-lg mx-auto px-6 md:px-10 lg:px-12">
          <div className="max-w-5xl mx-auto">
            <div className="bg-white border border-gray-200 rounded-2xl shadow-sm overflow-hidden">
              <div className="px-6 py-8 md:px-10 md:py-12 lg:px-14 lg:py-14">
                {isLoading && (
                  <div className="py-12 text-center text-gray-500" role="status">
                    Cargando Política de Cookies…
                  </div>
                )}

                {!isLoading && loadError && (
                  <div
                    className="rounded-xl border border-red-200 bg-red-50 p-6 text-red-700"
                    role="alert"
                  >
                    {loadError}
                  </div>
                )}

                {!isLoading && !loadError && document && (
                  <LegalText content={document.content} />
                )}
              </div>
            </div>

            {/* ======================================================
                VOLVER
                ====================================================== */}

            <div className="mt-8 text-center">
              <button
  onClick={() => {
    const previousPage = sessionStorage.getItem(
      "modira_previous_page"
    );

    if (previousPage) {
      const { url, scrollY } = JSON.parse(previousPage);

      sessionStorage.setItem(
        "modira_restore_scroll",
        String(scrollY)
      );

      window.location.href = url;
    } else {
      window.location.href = "/";
    }
  }}
  className="inline-flex items-center gap-2 text-sm font-medium text-[#1E3A8A] hover:text-[#16306F] transition-colors mb-8"
>
  <ArrowLeft size={18} />
  Volver
</button>
            </div>
          </div>
        </div>
      </main>

      {/* ========================================================
          ESTILOS DEL HEADER
          ======================================================== */}

      <style>{`
        /*
         * ========================================================
         * MODIRA — HEADER DE POLÍTICA DE COOKIES
         * ========================================================
         *
         * ARRIBA DEL TODO
         * ----------------
         * Header transparente.
         *
         * AL HACER SCROLL
         * ----------------
         * Header blanco.
         *
         * ========================================================
         */

        .cookie-policy-header-wrapper {
          position: relative;
          z-index: 50;
          transition:
            background-color 250ms ease,
            box-shadow 250ms ease;
        }

        /*
         * ========================================================
         * ESTADO INICIAL — TRANSPARENTE
         * ========================================================
         */

        .cookie-policy-header-transparent {
  background: linear-gradient(to right, #102A66, #173B8F) !important;
  box-shadow: 0 4px 12px rgba(16, 42, 102, 0.18) !important;
}

.cookie-policy-header-transparent header {
  background: linear-gradient(to right, #102A66, #173B8F) !important;
  box-shadow: none !important;
}

        /*
         * ========================================================
         * ESTADO CON SCROLL — BLANCO
         * ========================================================
         */

        .cookie-policy-header-scrolled {
          background-color: #ffffff !important;
          box-shadow: 0 1px 0 rgba(15, 23, 42, 0.06) !important;
        }

        .cookie-policy-header-scrolled header {
          background-color: #ffffff !important;
          box-shadow: none !important;
        }

        /*
         * ========================================================
         * PÁGINA
         * ========================================================
         */

        .cookie-policy-page {
          position: relative;
        }

        .cookie-policy-header-wrapper {
          min-height: 0;
        }
      `}</style>
    </div>
  );
}