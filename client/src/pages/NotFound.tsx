import { Home, ArrowLeft, AlertTriangle } from "lucide-react";
import { useLocation } from "wouter";

export default function NotFound() {
  const [, setLocation] = useLocation();

  const handleGoHome = () => {
    setLocation("/");
  };

  const handleGoBack = () => {
    window.history.back();
  };

  return (
    <div className="relative min-h-screen w-full overflow-hidden bg-[#071A3A] text-white flex items-center justify-center">

      {/* ============================================================
          FONDO
          ============================================================ */}

      <div className="absolute inset-0 bg-gradient-to-br from-[#071A3A] via-[#102A66] to-[#06152F]" />

      {/* Glow azul */}
      <div
        className="
          absolute
          -top-40
          -left-40
          w-[420px]
          h-[420px]
          rounded-full
          bg-blue-600/15
          blur-3xl
        "
      />

      <div
        className="
          absolute
          -bottom-40
          -right-40
          w-[420px]
          h-[420px]
          rounded-full
          bg-blue-400/10
          blur-3xl
        "
      />

      {/* ============================================================
          GRID
          ============================================================ */}

      <div
        className="
          absolute
          inset-0
          opacity-[0.055]
          pointer-events-none
        "
        style={{
          backgroundImage: `
            linear-gradient(rgba(255,255,255,0.5) 1px, transparent 1px),
            linear-gradient(90deg, rgba(255,255,255,0.5) 1px, transparent 1px)
          `,
          backgroundSize: "48px 48px",
        }}
      />

      {/* ============================================================
          PARTÍCULAS
          ============================================================ */}

      <div className="absolute inset-0 pointer-events-none overflow-hidden">
        <span className="absolute top-[18%] left-[15%] h-1 w-1 rounded-full bg-blue-300/50" />
        <span className="absolute top-[27%] right-[18%] h-1 w-1 rounded-full bg-blue-200/50" />
        <span className="absolute bottom-[24%] left-[22%] h-1 w-1 rounded-full bg-blue-300/40" />
        <span className="absolute bottom-[18%] right-[25%] h-1 w-1 rounded-full bg-blue-200/40" />
        <span className="absolute top-[42%] left-[8%] h-1 w-1 rounded-full bg-white/20" />
        <span className="absolute top-[65%] right-[10%] h-1 w-1 rounded-full bg-white/20" />
      </div>

      {/* ============================================================
          CONTENIDO
          ============================================================ */}

      <main className="relative z-10 w-full max-w-2xl px-5 sm:px-6 py-10 text-center">

        {/* Logo */}
        <div className="mb-7 flex justify-center">
          <button
            onClick={handleGoHome}
            className="
              group
              inline-flex
              items-center
              gap-1.5
              text-xl
              sm:text-2xl
              font-bold
              tracking-tight
              transition-all
              duration-300
              hover:scale-105
            "
            aria-label="Ir a la página principal de Modira"
          >
            <span className="text-white">
              modira
            </span>

            <span
              className="
                h-1.5
                w-1.5
                rounded-full
                bg-blue-400
                shadow-[0_0_12px_rgba(96,165,250,0.8)]
                transition-all
                duration-300
                group-hover:scale-125
              "
            />
          </button>
        </div>

        {/* ========================================================
            ICONO
            ======================================================== */}

        <div className="flex justify-center mb-5">
          <div className="relative">

            <div
              className="
                absolute
                inset-0
                rounded-2xl
                bg-blue-500/15
                blur-xl
                scale-125
              "
            />

            <div
              className="
                relative
                flex
                h-16
                w-16
                sm:h-18
                sm:w-18
                items-center
                justify-center
                rounded-2xl
                border
                border-white/10
                bg-white/[0.06]
                shadow-xl
                backdrop-blur-xl
              "
            >
              <AlertTriangle
                className="
                  h-7
                  w-7
                  sm:h-8
                  sm:w-8
                  text-blue-300
                "
                strokeWidth={1.7}
              />
            </div>
          </div>
        </div>

        {/* ========================================================
            404
            ======================================================== */}

        <div className="mb-1">
          <span
            className="
              bg-gradient-to-r
              from-white
              via-blue-100
              to-blue-300
              bg-clip-text
              text-transparent
              text-[clamp(4.5rem,14vw,7rem)]
              leading-none
              font-black
              tracking-[-0.07em]
            "
          >
            404
          </span>
        </div>

        {/* ========================================================
            TÍTULO
            ======================================================== */}

        <h1 className="text-xl sm:text-2xl font-bold tracking-tight mb-3">
          Esta página no existe
        </h1>

        {/* ========================================================
            DESCRIPCIÓN
            ======================================================== */}

        <p className="mx-auto max-w-lg text-sm sm:text-base leading-relaxed text-blue-100/65 mb-7">
          Parece que has llegado a un lugar que no podemos encontrar.
          <br className="hidden sm:block" />
          Puede que la página haya sido movida, eliminada o que la dirección
          no sea correcta.
        </p>

        {/* ========================================================
            BOTONES
            ======================================================== */}

        <div className="flex flex-col sm:flex-row items-center justify-center gap-2.5">

          {/* Inicio */}
          <button
            onClick={handleGoHome}
            className="
              group
              inline-flex
              w-full
              sm:w-auto
              items-center
              justify-center
              gap-2
              rounded-xl
              bg-blue-600
              px-5
              py-2.5
              text-sm
              font-semibold
              text-white
              shadow-lg
              shadow-blue-950/30
              transition-all
              duration-300
              hover:bg-blue-500
              hover:-translate-y-0.5
              hover:shadow-xl
              hover:shadow-blue-900/30
              active:translate-y-0
            "
          >
            <Home
              className="
                h-4
                w-4
                transition-transform
                duration-300
                group-hover:-translate-y-0.5
              "
            />

            Ir al inicio
          </button>

          {/* Atrás */}
          <button
            onClick={handleGoBack}
            className="
              group
              inline-flex
              w-full
              sm:w-auto
              items-center
              justify-center
              gap-2
              rounded-xl
              border
              border-white/15
              bg-white/[0.05]
              px-5
              py-2.5
              text-sm
              font-medium
              text-white
              backdrop-blur-md
              transition-all
              duration-300
              hover:bg-white/[0.10]
              hover:border-white/25
              hover:-translate-y-0.5
            "
          >
            <ArrowLeft
              className="
                h-4
                w-4
                transition-transform
                duration-300
                group-hover:-translate-x-1
              "
            />

            Volver atrás
          </button>
        </div>

        {/* ========================================================
            SEPARADOR
            ======================================================== */}

        <div className="mx-auto mt-9 mb-4 h-px w-20 bg-gradient-to-r from-transparent via-blue-300/20 to-transparent" />

        {/* ========================================================
            FOOTER
            ======================================================== */}

        <p className="text-[11px] text-blue-100/35">
          © {new Date().getFullYear()} Modira · Soluciones digitales
        </p>

      </main>
    </div>
  );
}