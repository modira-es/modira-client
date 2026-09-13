import {
  ArrowLeft,
  ArrowRight,
  CheckCircle2,
  ShieldCheck,
  Zap,
  Workflow,
  BrainCircuit,
  Link2,
  TrendingUp,
  Eye,
  Settings2,
  RefreshCw,
  LockKeyhole,
  CreditCard,
  FileCheck,
  LifeBuoy,
  Search,
  Sparkles,
  Target,
  Building2,
  Gauge,
  Layers3,
  Rocket,
  CircleCheck,
  Menu,
  X,
  BadgeCheck,
  Wrench,
} from "lucide-react";

import { useLocation } from "wouter";
import { useEffect, useState } from "react";

export default function WhoWeAre() {
  const [, setLocation] = useLocation();

  const [isOpen, setIsOpen] = useState(false);
  const [isScrolled, setIsScrolled] = useState(false);

  const [philosophyMode, setPhilosophyMode] = useState<
    "entendemos" | "transformamos" | "evolucionamos"
  >("entendemos");

  useEffect(() => {
    const handleScroll = () => {
      setIsScrolled(window.scrollY > 10);
    };

    window.addEventListener("scroll", handleScroll);

    return () => {
      window.removeEventListener("scroll", handleScroll);
    };
  }, []);

  /*
   * ============================================================
   * SCROLL REVEAL
   * ============================================================
   */

  useEffect(() => {
    const elements = document.querySelectorAll<HTMLElement>(
      ".scroll-reveal-item"
    );

    if (!elements.length) return;

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      {
        threshold: 0.1,
        rootMargin: "0px 0px -40px 0px",
      }
    );

    elements.forEach((element) => {
      observer.observe(element);
    });

    return () => {
      observer.disconnect();
    };
  }, []);

  /*
   * ============================================================
   * FILOSOFÍA
   * ============================================================
   */

  const philosophyContent = {
    entendemos: {
      label: "01 · Entendemos",
      title: "Primero entendemos el problema",
      description:
        "Antes de decidir qué tecnología utilizar, analizamos cómo funciona actualmente la empresa. Buscamos tareas repetitivas, procesos manuales, herramientas desconectadas y puntos donde se está perdiendo tiempo.",
      icon: Eye,
      items: [
        "Analizamos los procesos actuales.",
        "Detectamos tareas repetitivas.",
        "Identificamos puntos de mejora.",
      ],
    },

    transformamos: {
      label: "02 · Transformamos",
      title: "Después diseñamos la solución",
      description:
        "Convertimos la necesidad detectada en un sistema adaptado a los procesos reales de la empresa. Integramos las herramientas existentes y aplicamos automatización e inteligencia artificial cuando realmente aportan valor.",
      icon: Settings2,
      items: [
        "Diseñamos flujos personalizados.",
        "Conectamos las herramientas existentes.",
        "Aplicamos IA cuando tiene sentido.",
      ],
    },

    evolucionamos: {
      label: "03 · Evolucionamos",
      title: "Y seguimos mejorando",
      description:
        "Una automatización no debería quedarse congelada después de su implantación. Las empresas cambian, aparecen nuevas necesidades y los procesos evolucionan. Por eso diseñamos soluciones que puedan seguir creciendo.",
      icon: RefreshCw,
      items: [
        "Documentamos la solución.",
        "Ofrecemos soporte y mantenimiento.",
        "Preparamos el sistema para evolucionar.",
      ],
    },
  };

  const activePhilosophy = philosophyContent[philosophyMode];
  const ActivePhilosophyIcon = activePhilosophy.icon;

  /*
   * ============================================================
   * PRINCIPIOS
   * ============================================================
   */

  const principles = [
    {
      icon: Target,
      title: "Orientación a resultados",
      text: "Medimos el valor de una solución por el problema que resuelve, no por lo sofisticada que sea.",
    },
    {
      icon: Settings2,
      title: "Personalización",
      text: "Cada empresa tiene procesos diferentes. Diseñamos soluciones alrededor de las necesidades reales de cada negocio.",
    },
    {
      icon: Zap,
      title: "Simplicidad",
      text: "La tecnología debe facilitar el trabajo, no añadir complejidad innecesaria.",
    },
    {
      icon: ShieldCheck,
      title: "Seguridad",
      text: "La protección y el control de acceso forman parte del diseño de nuestras soluciones.",
    },
    {
      icon: Eye,
      title: "Transparencia",
      text: "Explicamos qué hacemos, cómo funciona la solución y qué puede esperar el cliente.",
    },
    {
      icon: TrendingUp,
      title: "Evolución",
      text: "Construimos soluciones que puedan adaptarse a medida que también evoluciona la empresa.",
    },
  ];

  /*
   * ============================================================
   * TECNOLOGÍAS
   * ============================================================
   */

  const technologies = [
    "Make",
    "n8n",
    "Inteligencia Artificial",
    "APIs",
    "WhatsApp Business",
    "Airtable",
    "Google Workspace",
    "Google Sheets",
  ];

  /*
   * ============================================================
   * EVOLUCIÓN
   * ============================================================
   */

  const evolutionSteps = [
    {
      number: "01",
      icon: LightbulbIcon,
      title: "Una idea",
      text: "Detectar una realidad sencilla: muchas empresas dedican tiempo a tareas repetitivas que podrían automatizarse.",
    },
    {
      number: "02",
      icon: Search,
      title: "Una metodología",
      text: "Convertir esa necesidad en una forma estructurada de analizar procesos, detectar oportunidades y diseñar soluciones.",
    },
    {
      number: "03",
      icon: Layers3,
      title: "Un ecosistema",
      text: "Desarrollar herramientas y sistemas que permitan gestionar proyectos, clientes, presupuestos, documentos, facturación y soporte.",
    },
    {
      number: "04",
      icon: Rocket,
      title: "Una visión",
      text: "Construir soluciones digitales que puedan crecer junto a las empresas y evolucionar con sus necesidades.",
    },
  ];

  /*
   * ============================================================
   * NAVEGACIÓN
   * ============================================================
   */

  const scrollToSection = (id: string) => {
    document.getElementById(id)?.scrollIntoView({
      behavior: "smooth",
    });

    setIsOpen(false);
  };

  return (
    <div className="min-h-screen bg-white">

      {/* ========================================================
          ESTILOS
          ======================================================== */}

      <style>{`

        .scroll-reveal-item {
          opacity: 0;
          transform: translateY(24px);
          transition:
            opacity 700ms ease-out,
            transform 700ms cubic-bezier(0.22, 1, 0.36, 1);
          will-change: transform, opacity;
        }

        .scroll-reveal-item.is-visible {
          opacity: 1;
          transform: translateY(0);
        }

        .flow-particle {
          animation: flowParticle 3s linear infinite;
        }

        .flow-particle-delay-1 {
          animation-delay: 0.8s;
        }

        .flow-particle-delay-2 {
          animation-delay: 1.6s;
        }

        .flow-particle-delay-3 {
          animation-delay: 2.4s;
        }

        .hero-orbit {
          animation: rotateFlow 18s linear infinite;
          transform-origin: center;
        }

        .hero-orbit-reverse {
          animation: rotateFlowReverse 24s linear infinite;
          transform-origin: center;
        }

        .core-pulse {
          animation: corePulse 3s ease-in-out infinite;
        }

        .soft-float {
          animation: softFloat 4s ease-in-out infinite;
        }

        .soft-float-delay {
          animation: softFloat 4s ease-in-out infinite;
          animation-delay: 1.2s;
        }

        .soft-float-delay-2 {
          animation: softFloat 4s ease-in-out infinite;
          animation-delay: 2.2s;
        }

        .security-pulse {
          animation: securityPulse 2.8s ease-in-out infinite;
        }

        @keyframes rotateFlow {
          from {
            transform: rotate(0deg);
          }

          to {
            transform: rotate(360deg);
          }
        }

        @keyframes rotateFlowReverse {
          from {
            transform: rotate(360deg);
          }

          to {
            transform: rotate(0deg);
          }
        }

        @keyframes corePulse {
          0%, 100% {
            transform: scale(1);
            opacity: 0.35;
          }

          50% {
            transform: scale(1.12);
            opacity: 0.75;
          }
        }

        @keyframes softFloat {
          0%, 100% {
            transform: translateY(0);
          }

          50% {
            transform: translateY(-7px);
          }
        }

        @keyframes securityPulse {
          0%, 100% {
            opacity: 0.35;
            transform: scale(1);
          }

          50% {
            opacity: 0.75;
            transform: scale(1.08);
          }
        }

        @media (prefers-reduced-motion: reduce) {
          .scroll-reveal-item {
            opacity: 1 !important;
            transform: none !important;
            transition: none !important;
          }

          .flow-particle,
          .flow-particle-delay-1,
          .flow-particle-delay-2,
          .flow-particle-delay-3,
          .hero-orbit,
          .hero-orbit-reverse,
          .core-pulse,
          .soft-float,
          .soft-float-delay,
          .soft-float-delay-2,
          .security-pulse {
            animation: none !important;
          }
        }

      `}</style>


      {/* ========================================================
          HEADER
          ======================================================== */}

      <header
        className={`fixed top-0 left-0 z-50 h-[80px] w-full transition-all duration-300 ${
          isScrolled
            ? "bg-white/95 backdrop-blur-md shadow-lg border-b border-[#102A66]/10"
            : "bg-gradient-to-r from-[#102A66] to-[#173B8F] shadow-lg"
        }`}
      >
        <nav className="container mx-auto h-[80px] pl-10 pr-4 flex items-center justify-between">

          {/* LOGO */}

          <div className="flex items-center gap-3 h-full">
            <img
              src={
                isScrolled
                  ? import.meta.env.VITE_APP_LOGO_DARK
                  : import.meta.env.VITE_APP_LOGO
              }
              alt="Modira"
              className="h-8 w-auto object-contain transition-all duration-300"
            />

            <span
              className={`modira-font text-xl leading-none flex items-center translate-y-[2px] transition-colors duration-300 ${
                isScrolled ? "text-[#102A66]" : "text-white"
              }`}
            >
              MODIRA
            </span>
          </div>


          {/* DESKTOP NAVIGATION */}

          <div className="hidden md:flex items-center gap-6">

            <nav className="flex items-center gap-6">

              <button
                type="button"
                onClick={() => scrollToSection("modira")}
                className={`text-[14px] font-medium transition-colors duration-300 ${
                  isScrolled
                    ? "text-[#102A66]/80 hover:text-[#102A66]"
                    : "text-white/80 hover:text-white"
                }`}
              >
                Qué es Modira
              </button>

              <button
                type="button"
                onClick={() => scrollToSection("filosofia")}
                className={`text-[14px] font-medium transition-colors duration-300 ${
                  isScrolled
                    ? "text-[#102A66]/80 hover:text-[#102A66]"
                    : "text-white/80 hover:text-white"
                }`}
              >
                Nuestra filosofía
              </button>

              <button
                type="button"
                onClick={() => scrollToSection("garantia")}
                className={`text-[14px] font-medium transition-colors duration-300 ${
                  isScrolled
                    ? "text-[#102A66]/80 hover:text-[#102A66]"
                    : "text-white/80 hover:text-white"
                }`}
              >
                Garantía
              </button>

            </nav>


            {/* ÁREA PRINCIPAL */}

            <button
              type="button"
              onClick={() => setLocation("/")}
              className={`inline-flex items-center gap-2 rounded-lg px-5 py-2.5 text-sm font-semibold shadow-md transition-all duration-300 ${
                isScrolled
                  ? "bg-[#102A66] text-white hover:bg-[#173B8F]"
                  : "bg-white text-[#102A66] hover:bg-white/90"
              }`}
            >
              <ArrowLeft className="h-4 w-4" />
              Área principal
            </button>

          </div>


          {/* MOBILE MENU BUTTON */}

          <button
            type="button"
            className={`md:hidden transition-colors duration-300 ${
              isScrolled ? "text-[#102A66]" : "text-white"
            }`}
            onClick={() => setIsOpen(!isOpen)}
            aria-label="Abrir menú"
          >
            {isOpen ? <X size={24} /> : <Menu size={24} />}
          </button>

        </nav>


        {/* MOBILE NAVIGATION */}

        {isOpen && (
          <div
            className={`md:hidden absolute top-[80px] left-0 w-full border-b px-4 py-4 space-y-3 shadow-lg transition-colors duration-300 ${
              isScrolled
                ? "bg-white border-[#102A66]/10"
                : "bg-[#102A66] border-white/20"
            }`}
          >

            <button
              type="button"
              onClick={() => scrollToSection("modira")}
              className={`block w-full text-left py-2 text-[15px] font-medium transition-colors ${
                isScrolled
                  ? "text-[#102A66]/80 hover:text-[#102A66]"
                  : "text-white/80 hover:text-white"
              }`}
            >
              Qué es Modira
            </button>

            <button
              type="button"
              onClick={() => scrollToSection("filosofia")}
              className={`block w-full text-left py-2 text-[15px] font-medium transition-colors ${
                isScrolled
                  ? "text-[#102A66]/80 hover:text-[#102A66]"
                  : "text-white/80 hover:text-white"
              }`}
            >
              Nuestra filosofía
            </button>

            <button
              type="button"
              onClick={() => scrollToSection("garantia")}
              className={`block w-full text-left py-2 text-[15px] font-medium transition-colors ${
                isScrolled
                  ? "text-[#102A66]/80 hover:text-[#102A66]"
                  : "text-white/80 hover:text-white"
              }`}
            >
              Garantía
            </button>

            <button
              type="button"
              onClick={() => {
                setLocation("/");
                setIsOpen(false);
              }}
              className={`w-full text-[15px] font-semibold mt-2 rounded-lg px-4 py-2.5 flex items-center justify-center gap-2 transition-all duration-300 ${
                isScrolled
                  ? "bg-[#102A66] text-white hover:bg-[#173B8F]"
                  : "bg-white text-[#102A66] hover:bg-white/90"
              }`}
            >
              <ArrowLeft className="h-4 w-4" />
              Área principal
            </button>

          </div>
        )}

      </header>


      {/* ========================================================
          HERO
          ======================================================== */}

      <section className="bg-[#102A66] pt-[70px] overflow-hidden">

        <div className="container mx-auto max-w-[1440px] px-6 sm:px-8 lg:px-12 xl:px-16 py-8 md:py-10">

          <div className="flex items-center justify-between gap-10">

            {/* TEXTO */}

            <div className="min-w-0">

              <h1 className="text-[40px] md:text-[44px] lg:text-[47px] font-bold text-white leading-[1.25] tracking-[0em]">
                Quiénes somos
              </h1>

              <p className="mt-7 text-[17px] md:text-[18px] text-white/85 leading-[1.5] max-w-[620px]">
                Conoce Modira, nuestra forma de entender la tecnología y por
                qué trabajamos para convertir procesos manuales en sistemas
                que trabajan por ti.
              </p>

            </div>


            {/* VISUAL HERO */}

            <div className="hidden md:flex relative w-[260px] h-[190px] shrink-0 items-center justify-center mr-12 lg:mr-18">

              {/* ANILLOS */}

              <div className="absolute w-[118px] h-[118px] rounded-full border border-white/[0.12]" />

              <div className="absolute w-[155px] h-[155px] rounded-full border border-white/[0.08]" />

              <div className="absolute w-[155px] h-[155px] rounded-full border border-dashed border-white/[0.14] hero-orbit" />

              <div className="absolute w-[190px] h-[190px] rounded-full border border-dotted border-white/[0.06] hero-orbit-reverse" />


              {/* CONEXIONES */}

              <svg
                className="absolute inset-0 w-full h-full overflow-visible"
                viewBox="0 0 260 190"
                fill="none"
              >

                <path
                  d="M130 95 C130 70 130 50 130 24"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth="1.4"
                />

                <path
                  d="M145 87 C170 70 195 55 224 52"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth="1.4"
                />

                <path
                  d="M145 103 C170 120 195 135 224 138"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth="1.4"
                />

                <path
                  d="M115 87 C90 70 65 55 36 52"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth="1.4"
                />

                <path
                  d="M115 103 C90 120 65 135 36 138"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth="1.4"
                />

                <path
                  d="M130 110 C130 135 130 150 130 166"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth="1.4"
                />


                {/* PARTÍCULAS */}

                <circle r="2" fill="rgba(255,255,255,0.95)">
                  <animateMotion
                    dur="2.8s"
                    repeatCount="indefinite"
                    path="M130 95 C130 70 130 50 130 24"
                  />
                </circle>

                <circle r="1.7" fill="rgba(255,255,255,0.88)">
                  <animateMotion
                    dur="3.4s"
                    begin="0.8s"
                    repeatCount="indefinite"
                    path="M145 87 C170 70 195 55 224 52"
                  />
                </circle>

                <circle r="1.7" fill="rgba(255,255,255,0.88)">
                  <animateMotion
                    dur="3.1s"
                    begin="1.2s"
                    repeatCount="indefinite"
                    path="M145 103 C170 120 195 135 224 138"
                  />
                </circle>

                <circle r="1.7" fill="rgba(255,255,255,0.82)">
                  <animateMotion
                    dur="3.5s"
                    begin="0.4s"
                    repeatCount="indefinite"
                    path="M115 87 C90 70 65 55 36 52"
                  />
                </circle>

                <circle r="1.7" fill="rgba(255,255,255,0.82)">
                  <animateMotion
                    dur="3.2s"
                    begin="1.5s"
                    repeatCount="indefinite"
                    path="M115 103 C90 120 65 135 36 138"
                  />
                </circle>

                <circle r="1.7" fill="rgba(255,255,255,0.88)">
                  <animateMotion
                    dur="3.3s"
                    begin="0.6s"
                    repeatCount="indefinite"
                    path="M130 110 C130 135 130 150 130 166"
                  />
                </circle>

              </svg>


              {/* NÚCLEO */}

              <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 flex items-center justify-center">

                <div className="absolute w-[82px] h-[82px] rounded-full border border-white/[0.12] core-pulse" />

                <div className="relative w-[58px] h-[58px] rounded-full border border-white/25 bg-[#21489A]/75 backdrop-blur-md flex items-center justify-center shadow-[0_0_30px_rgba(255,255,255,0.10)]">

                  <div className="text-[10px] font-semibold tracking-[0.12em] text-white">
                    MODIRA
                  </div>

                </div>

              </div>


              {/* NODOS */}

              <div className="absolute top-[8px] left-1/2 -translate-x-1/2">
                <div className="w-[34px] h-[34px] rounded-full border border-white/20 bg-white/[0.09] backdrop-blur-sm flex items-center justify-center">
                  <BrainCircuit
                    className="w-[16px] h-[16px] text-white/85"
                    strokeWidth={1.5}
                  />
                </div>
              </div>

              <div className="absolute right-[7px] top-[35px]">
                <div className="w-[34px] h-[34px] rounded-full border border-white/20 bg-white/[0.09] backdrop-blur-sm flex items-center justify-center">
                  <Link2
                    className="w-[17px] h-[17px] text-white/85"
                    strokeWidth={1.5}
                  />
                </div>
              </div>

              <div className="absolute right-[7px] bottom-[35px]">
                <div className="w-[34px] h-[34px] rounded-full border border-white/20 bg-white/[0.09] backdrop-blur-sm flex items-center justify-center">
                  <TrendingUp
                    className="w-[16px] h-[16px] text-white/85"
                    strokeWidth={1.5}
                  />
                </div>
              </div>

              <div className="absolute left-[7px] top-[35px]">
                <div className="w-[34px] h-[34px] rounded-full border border-white/20 bg-white/[0.09] backdrop-blur-sm flex items-center justify-center">
                  <Workflow
                    className="w-[16px] h-[16px] text-white/85"
                    strokeWidth={1.5}
                  />
                </div>
              </div>

              <div className="absolute left-[7px] bottom-[35px]">
                <div className="w-[34px] h-[34px] rounded-full border border-white/20 bg-white/[0.09] backdrop-blur-sm flex items-center justify-center">
                  <Zap
                    className="w-[16px] h-[16px] text-white/85"
                    strokeWidth={1.5}
                  />
                </div>
              </div>

              <div className="absolute bottom-[4px] left-1/2 -translate-x-1/2">
                <div className="w-[34px] h-[34px] rounded-full border border-white/20 bg-white/[0.09] backdrop-blur-sm flex items-center justify-center">
                  <Target
                    className="w-[16px] h-[16px] text-white/85"
                    strokeWidth={1.5}
                  />
                </div>
              </div>

            </div>

          </div>

        </div>

      </section>


      <main>


        {/* ========================================================
            INTRO — QUÉ ES MODIRA
            ======================================================== */}

        <section
          id="modira"
          className="relative bg-white py-14 md:py-20 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-[#F4F6F9] before:to-white"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-4xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Qué es Modira
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                Tecnología al servicio de tu empresa
              </h2>

              <p className="scroll-reveal-item mt-5 text-base leading-relaxed text-[#52627A] md:text-lg">
                Modira es una empresa española especializada en automatización
                empresarial, integración de procesos e inteligencia artificial.
                Ayudamos a las empresas a eliminar tareas repetitivas,
                conectar las herramientas que ya utilizan y crear procesos más
                eficientes.
              </p>

            </div>


            {/* BLOQUE PRINCIPAL */}

            <div className="mx-auto mt-12 max-w-6xl">

              <div className="grid gap-8 lg:grid-cols-[1.05fr_0.95fr]">

                {/* TEXTO */}

                <div className="scroll-reveal-item rounded-3xl border border-[#E1E7EF] bg-[#F8FAFC] p-8 md:p-10">

                  <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F]">
                    <Building2 className="h-6 w-6" />
                  </div>

                  <h3 className="mt-6 text-2xl font-bold text-[#102A66] md:text-3xl">
                    No vendemos tecnología por vender tecnología
                  </h3>

                  <p className="mt-4 leading-relaxed text-[#52627A]">
                    Nuestro objetivo es encontrar dónde la tecnología puede
                    aportar un beneficio real al negocio. Una automatización
                    tiene sentido cuando consigue ahorrar tiempo, reducir
                    errores, conectar información o liberar al equipo de tareas
                    repetitivas.
                  </p>

                  <p className="mt-4 leading-relaxed text-[#52627A]">
                    Por eso nuestras soluciones parten del proceso de cada
                    empresa y no de una plantilla cerrada.
                  </p>

                  <button
                    type="button"
                    onClick={() => setLocation("/como-trabajamos")}
                    className="mt-7 inline-flex items-center gap-2 rounded-lg bg-[#173B8F] px-6 py-3 font-semibold text-white shadow-sm transition hover:bg-[#102A66]"
                  >
                    Conoce cómo trabajamos
                    <ArrowRight className="h-4 w-4" />
                  </button>

                </div>


                {/* RESULTADOS */}

                <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-1">

                  {[
                    {
                      icon: Zap,
                      title: "Menos trabajo manual",
                      text: "Automatizamos tareas repetitivas para liberar tiempo.",
                    },
                    {
                      icon: Link2,
                      title: "Herramientas conectadas",
                      text: "Integramos aplicaciones para evitar trabajo duplicado.",
                    },
                    {
                      icon: Gauge,
                      title: "Procesos más eficientes",
                      text: "Reducimos pasos innecesarios y mejoramos los flujos.",
                    },
                    {
                      icon: TrendingUp,
                      title: "Más capacidad para crecer",
                      text: "Liberamos al equipo para tareas de mayor valor.",
                    },
                  ].map((item) => (
                    <div
                      key={item.title}
                      className="scroll-reveal-item rounded-2xl border border-[#E1E7EF] bg-white p-6 shadow-sm"
                    >

                      <div className="flex items-start gap-4">

                        <div className="flex h-11 w-11 flex-shrink-0 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F]">
                          <item.icon className="h-5 w-5" />
                        </div>

                        <div>
                          <h3 className="font-bold text-[#102A66]">
                            {item.title}
                          </h3>

                          <p className="mt-1 text-sm leading-relaxed text-[#52627A]">
                            {item.text}
                          </p>
                        </div>

                      </div>

                    </div>
                  ))}

                </div>

              </div>

            </div>

          </div>

        </section>


        {/* ========================================================
            POR QUÉ EXISTE MODIRA
            ======================================================== */}

        <section
          className="relative bg-[#F4F6F9] py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-white before:to-[#F4F6F9]"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Por qué existe Modira
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                Demasiadas empresas siguen haciendo manualmente lo que una
                máquina podría hacer por ellas
              </h2>

              <p className="scroll-reveal-item mt-4 text-[#52627A] md:text-lg">
                Introducir información, copiar datos entre herramientas,
                revisar tareas repetitivas o responder manualmente son
                pequeñas acciones que, acumuladas, consumen una cantidad
                importante de tiempo.
              </p>

            </div>


            {/* FLUJO */}

            <div className="mx-auto mt-14 max-w-6xl">

              <div className="relative grid gap-5 md:grid-cols-4">

                {[
                  {
                    icon: FileCheck,
                    number: "01",
                    title: "Tareas repetitivas",
                    text: "Trabajo manual que se repite una y otra vez.",
                  },
                  {
                    icon: Workflow,
                    number: "02",
                    title: "Procesos desconectados",
                    text: "Información que debe trasladarse entre herramientas.",
                  },
                  {
                    icon: AlertTriangleIcon,
                    number: "03",
                    title: "Tiempo perdido",
                    text: "Horas que podrían dedicarse a tareas de mayor valor.",
                  },
                  {
                    icon: Sparkles,
                    number: "04",
                    title: "Automatización",
                    text: "Procesos más rápidos, conectados y eficientes.",
                  },
                ].map((item, index) => (
                  <div
                    key={item.number}
                    className="relative"
                  >

                    <div className="scroll-reveal-item h-full rounded-2xl border border-[#E1E7EF] bg-white p-6 shadow-sm">

                      <div className="flex items-center justify-between">

                        <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F]">
                          <item.icon className="h-5 w-5" />
                        </div>

                        <span className="text-xs font-bold tracking-[0.15em] text-[#173B8F]/60">
                          {item.number}
                        </span>

                      </div>

                      <h3 className="mt-5 text-lg font-bold text-[#102A66]">
                        {item.title}
                      </h3>

                      <p className="mt-2 text-sm leading-relaxed text-[#52627A]">
                        {item.text}
                      </p>

                    </div>


                    {index < 3 && (
                      <div className="hidden md:flex absolute -right-4 top-1/2 z-10 -translate-y-1/2">

                        <div className="flex h-8 w-8 items-center justify-center rounded-full border border-[#D8E1EF] bg-[#F4F6F9] text-[#173B8F]">
                          <ArrowRight className="h-4 w-4" />
                        </div>

                      </div>
                    )}

                  </div>
                ))}

              </div>

            </div>

          </div>

        </section>


        {/* ========================================================
            QUÉ HACEMOS — FLUJO DINÁMICO
            ======================================================== */}

        <section
          className="relative bg-white py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-[#F4F6F9] before:to-white"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Qué hacemos
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                Convertimos procesos en sistemas
              </h2>

              <p className="scroll-reveal-item mt-4 text-[#52627A] md:text-lg">
                Combinamos automatización, inteligencia artificial e
                integración de herramientas para crear soluciones adaptadas a
                cada empresa.
              </p>

            </div>


            {/* FLUJO DINÁMICO */}

            <div className="scroll-reveal-item mx-auto mt-14 max-w-6xl rounded-3xl border border-[#E1E7EF] bg-[#F8FAFC] p-6 md:p-10">

              <div className="relative">

                {/* LÍNEA DESKTOP */}

                <div className="absolute left-[12%] right-[12%] top-[42px] hidden h-px bg-[#D5DEEB] md:block" />

                {/* PARTÍCULAS */}

                <div className="absolute left-[18%] top-[40px] hidden h-[4px] w-[4px] rounded-full bg-[#173B8F] md:block flow-particle" />

                <div className="absolute left-[18%] top-[40px] hidden h-[4px] w-[4px] rounded-full bg-[#173B8F] md:block flow-particle flow-particle-delay-1" />

                <div className="absolute left-[18%] top-[40px] hidden h-[4px] w-[4px] rounded-full bg-[#173B8F] md:block flow-particle flow-particle-delay-2" />


                <div className="grid gap-8 md:grid-cols-4">

                  {[
                    {
                      icon: Building2,
                      title: "Tu empresa",
                      text: "Procesos, herramientas y necesidades reales.",
                    },
                    {
                      icon: Search,
                      title: "Detectamos",
                      text: "Encontramos tareas y puntos de mejora.",
                    },
                    {
                      icon: Workflow,
                      title: "Automatizamos",
                      text: "Conectamos herramientas y construimos el flujo.",
                    },
                    {
                      icon: TrendingUp,
                      title: "Resultado",
                      text: "Más eficiencia, menos trabajo manual.",
                    },
                  ].map((item, index) => (
                    <div
                      key={item.title}
                      className="relative z-10 text-center"
                    >

                      <div className="mx-auto flex h-[84px] w-[84px] items-center justify-center rounded-full border border-[#D8E1EF] bg-white shadow-sm">

                        <div className="flex h-[54px] w-[54px] items-center justify-center rounded-full bg-[#173B8F]/10 text-[#173B8F]">

                          <item.icon className="h-6 w-6" />

                        </div>

                      </div>

                      <h3 className="mt-5 text-lg font-bold text-[#102A66]">
                        {item.title}
                      </h3>

                      <p className="mx-auto mt-2 max-w-[210px] text-sm leading-relaxed text-[#52627A]">
                        {item.text}
                      </p>

                    </div>
                  ))}

                </div>

              </div>

            </div>


            {/* 4 ÁREAS */}

            <div className="mx-auto mt-8 grid max-w-6xl gap-5 md:grid-cols-4">

              {[
                {
                  icon: Zap,
                  title: "Automatizamos",
                  text: "Convertimos tareas repetitivas en flujos automáticos.",
                },
                {
                  icon: Link2,
                  title: "Conectamos",
                  text: "Integramos las herramientas que ya utiliza la empresa.",
                },
                {
                  icon: BrainCircuit,
                  title: "Aplicamos inteligencia",
                  text: "Utilizamos IA cuando puede aportar valor real.",
                },
                {
                  icon: TrendingUp,
                  title: "Optimizamos",
                  text: "Buscamos que los procesos sean cada vez más eficientes.",
                },
              ].map((item) => (
                <div
                  key={item.title}
                  className="scroll-reveal-item rounded-2xl border border-[#E1E7EF] bg-white p-6"
                >

                  <item.icon className="h-6 w-6 text-[#173B8F]" />

                  <h3 className="mt-4 font-bold text-[#102A66]">
                    {item.title}
                  </h3>

                  <p className="mt-2 text-sm leading-relaxed text-[#52627A]">
                    {item.text}
                  </p>

                </div>
              ))}

            </div>

          </div>

        </section>


        {/* ========================================================
            FILOSOFÍA INTERACTIVA
            ======================================================== */}

        <section
          id="filosofia"
          className="relative bg-[#F4F6F9] py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-white before:to-[#F4F6F9]"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Nuestra filosofía
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                La tecnología debe adaptarse a la empresa
              </h2>

              <p className="scroll-reveal-item mt-4 text-[#52627A] md:text-lg">
                No creemos en soluciones genéricas para problemas diferentes.
                Primero entendemos. Después transformamos. Y finalmente
                evolucionamos.
              </p>

            </div>


            {/* SELECTOR */}

            <div className="scroll-reveal-item mx-auto mt-10 flex max-w-2xl flex-col gap-2 rounded-2xl border border-[#DCE4EF] bg-white p-2 sm:flex-row">

              {[
                {
                  key: "entendemos" as const,
                  label: "Entendemos",
                  icon: Eye,
                },
                {
                  key: "transformamos" as const,
                  label: "Transformamos",
                  icon: Settings2,
                },
                {
                  key: "evolucionamos" as const,
                  label: "Evolucionamos",
                  icon: RefreshCw,
                },
              ].map((item) => (
                <button
                  key={item.key}
                  type="button"
                  onClick={() => setPhilosophyMode(item.key)}
                  className={`flex flex-1 items-center justify-center gap-2 rounded-xl px-4 py-3 text-sm font-semibold transition-all ${
                    philosophyMode === item.key
                      ? "bg-[#173B8F] text-white shadow-sm"
                      : "text-[#52627A] hover:bg-[#F4F6F9] hover:text-[#102A66]"
                  }`}
                >
                  <item.icon className="h-4 w-4" />
                  {item.label}
                </button>
              ))}

            </div>


            {/* CONTENIDO */}

            <div className="mx-auto mt-8 max-w-5xl">

              <div className="grid gap-8 rounded-3xl border border-[#DCE4EF] bg-white p-7 md:grid-cols-[0.8fr_1.2fr] md:p-10">

                <div className="flex items-center justify-center">

                  <div className="relative flex h-[190px] w-[190px] items-center justify-center">

                    <div className="absolute inset-0 rounded-full border border-[#173B8F]/10" />

                    <div className="absolute inset-[20px] rounded-full border border-[#173B8F]/10" />

                    <div className="absolute inset-[40px] rounded-full border border-[#173B8F]/10" />

                    <div className="relative flex h-[76px] w-[76px] items-center justify-center rounded-2xl bg-gradient-to-br from-[#102A66] to-[#173B8F] text-white shadow-lg">

                      <ActivePhilosophyIcon className="h-8 w-8" />

                    </div>

                  </div>

                </div>


                <div>

                  <p className="text-sm font-bold uppercase tracking-[0.14em] text-[#173B8F]">
                    {activePhilosophy.label}
                  </p>

                  <h3 className="mt-2 text-2xl font-bold text-[#102A66] md:text-3xl">
                    {activePhilosophy.title}
                  </h3>

                  <p className="mt-4 leading-relaxed text-[#52627A]">
                    {activePhilosophy.description}
                  </p>

                  <div className="mt-6 space-y-3">

                    {activePhilosophy.items.map((item) => (
                      <div
                        key={item}
                        className="flex items-start gap-3"
                      >

                        <CheckCircle2 className="mt-0.5 h-5 w-5 flex-shrink-0 text-[#173B8F]" />

                        <span className="text-sm leading-relaxed text-[#52627A]">
                          {item}
                        </span>

                      </div>
                    ))}

                  </div>

                </div>

              </div>

            </div>


            {/* BOTÓN A CÓMO TRABAJAMOS */}

            <div className="scroll-reveal-item mt-10 text-center">

              <button
                type="button"
                onClick={() => setLocation("/como-trabajamos")}
                className="inline-flex items-center gap-2 rounded-lg border border-[#173B8F]/20 bg-white px-6 py-3 font-semibold text-[#173B8F] shadow-sm transition hover:border-[#173B8F] hover:bg-[#173B8F] hover:text-white"
              >
                Ver nuestro proceso completo
                <ArrowRight className="h-4 w-4" />
              </button>

            </div>

          </div>

        </section>


        {/* ========================================================
            TECNOLOGÍA
            ======================================================== */}

        <section
          className="relative bg-white py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-[#F4F6F9] before:to-white"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Tecnología
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                Utilizamos la tecnología que mejor encaja
              </h2>

              <p className="scroll-reveal-item mt-4 text-[#52627A] md:text-lg">
                No construimos los procesos alrededor de una única herramienta.
                Seleccionamos y combinamos las tecnologías que mejor responden
                a cada necesidad.
              </p>

            </div>


            <div className="mx-auto mt-12 max-w-5xl">

              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">

                {technologies.map((technology, index) => (
                  <div
                    key={technology}
                    className="scroll-reveal-item group rounded-2xl border border-[#E1E7EF] bg-[#F8FAFC] p-5 text-center transition-all duration-300 hover:-translate-y-1 hover:border-[#173B8F]/30 hover:bg-white hover:shadow-md"
                  >

                    <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F] transition group-hover:bg-[#173B8F] group-hover:text-white">

                      {index === 0 && <Workflow className="h-5 w-5" />}
                      {index === 1 && <Layers3 className="h-5 w-5" />}
                      {index === 2 && <BrainCircuit className="h-5 w-5" />}
                      {index === 3 && <Link2 className="h-5 w-5" />}
                      {index === 4 && <MessageSquareIcon className="h-5 w-5" />}
                      {index === 5 && <DatabaseIcon className="h-5 w-5" />}
                      {index === 6 && <CloudIcon className="h-5 w-5" />}
                      {index === 7 && <FileCheck className="h-5 w-5" />}

                    </div>

                    <h3 className="mt-4 text-sm font-bold text-[#102A66]">
                      {technology}
                    </h3>

                  </div>
                ))}

              </div>


              <div className="scroll-reveal-item mt-8 rounded-2xl border border-[#DCE4EF] bg-[#F4F6F9] p-6 text-center">

                <p className="text-sm leading-relaxed text-[#52627A]">
                  Y más herramientas, APIs e integraciones compatibles según
                  las necesidades de cada proyecto.
                </p>

              </div>

            </div>

          </div>

        </section>


        {/* ========================================================
            SEGURIDAD
            ======================================================== */}

        <section
          id="seguridad"
          className="relative bg-[#F4F6F9] py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-white before:to-[#F4F6F9]"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Seguridad y confianza
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                La automatización también debe proteger la información
              </h2>

              <p className="scroll-reveal-item mt-4 text-[#52627A] md:text-lg">
                Diseñamos nuestros sistemas teniendo en cuenta el control de
                acceso, la separación de la información y la seguridad de las
                operaciones.
              </p>

            </div>


            {/* FLUJO SEGURIDAD */}

            <div className="mx-auto mt-14 max-w-6xl">

              <div className="relative rounded-3xl border border-[#DCE4EF] bg-white p-7 md:p-10">

                <div className="grid gap-8 md:grid-cols-5">

                  {[
                    {
                      icon: LockKeyhole,
                      title: "Acceso",
                      text: "Usuarios autenticados.",
                    },
                    {
                      icon: Building2,
                      title: "Empresa",
                      text: "Información separada.",
                    },
                    {
                      icon: ShieldCheck,
                      title: "Permisos",
                      text: "Acceso controlado.",
                    },
                    {
                      icon: CreditCard,
                      title: "Pagos",
                      text: "Procesados mediante Stripe.",
                    },
                    {
                      icon: CheckCircle2,
                      title: "Control",
                      text: "Operaciones verificadas.",
                    },
                  ].map((item, index) => (
                    <div
                      key={item.title}
                      className="relative text-center"
                    >

                      <div className="security-pulse mx-auto flex h-16 w-16 items-center justify-center rounded-2xl bg-[#173B8F]/10 text-[#173B8F]">

                        <item.icon className="h-7 w-7" />

                      </div>

                      <h3 className="mt-4 font-bold text-[#102A66]">
                        {item.title}
                      </h3>

                      <p className="mt-1 text-sm text-[#52627A]">
                        {item.text}
                      </p>

                      {index < 4 && (
                        <div className="absolute -right-5 top-7 hidden md:block">

                          <ArrowRight className="h-5 w-5 text-[#B9C6D8]" />

                        </div>
                      )}

                    </div>
                  ))}

                </div>

              </div>

            </div>


            {/* CARDS */}

            <div className="mx-auto mt-8 grid max-w-6xl gap-5 md:grid-cols-3">

              {[
                {
                  icon: ShieldCheck,
                  title: "Información separada",
                  text: "La arquitectura de acceso está diseñada para que cada cliente pueda consultar únicamente la información que corresponde a su cuenta y empresa.",
                },
                {
                  icon: LockKeyhole,
                  title: "Control de permisos",
                  text: "El sistema utiliza autenticación y políticas de acceso para controlar qué operaciones puede realizar cada tipo de usuario.",
                },
                {
                  icon: CreditCard,
                  title: "Pagos protegidos",
                  text: "Los pagos de facturas se procesan mediante Stripe y la confirmación del pago se realiza mediante backend y webhook.",
                },
              ].map((item) => (
                <div
                  key={item.title}
                  className="scroll-reveal-item rounded-2xl border border-[#DCE4EF] bg-white p-6"
                >

                  <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F]">
                    <item.icon className="h-5 w-5" />
                  </div>

                  <h3 className="mt-5 text-lg font-bold text-[#102A66]">
                    {item.title}
                  </h3>

                  <p className="mt-2 text-sm leading-relaxed text-[#52627A]">
                    {item.text}
                  </p>

                </div>
              ))}

            </div>

          </div>

        </section>


        {/* ========================================================
            PRINCIPIOS
            ======================================================== */}

        <section
          className="relative bg-white py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-[#F4F6F9] before:to-white"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Nuestros principios
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                Lo que guía nuestro trabajo
              </h2>

            </div>


            <div className="mx-auto mt-12 grid max-w-6xl gap-5 md:grid-cols-2 lg:grid-cols-3">

              {principles.map((item) => (
                <div
                  key={item.title}
                  className="scroll-reveal-item rounded-2xl border border-[#E1E7EF] bg-[#F8FAFC] p-7 transition-all duration-300 hover:-translate-y-1 hover:bg-white hover:shadow-md"
                >

                  <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F]">
                    <item.icon className="h-5 w-5" />
                  </div>

                  <h3 className="mt-5 text-xl font-bold text-[#102A66]">
                    {item.title}
                  </h3>

                  <p className="mt-2 leading-relaxed text-[#52627A]">
                    {item.text}
                  </p>

                </div>
              ))}

            </div>

          </div>

        </section>


        {/* ========================================================
            EVOLUCIÓN / TRAYECTORIA
            ======================================================== */}

        <section
          id="trayectoria"
          className="relative bg-[#F4F6F9] py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-white before:to-[#F4F6F9]"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Nuestra evolución
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                Construimos Modira para el largo plazo
              </h2>

              <p className="scroll-reveal-item mt-4 text-[#52627A] md:text-lg">
                Modira evoluciona alrededor de una idea: ayudar a las empresas
                a trabajar de una forma más eficiente mediante tecnología que
                realmente aporte valor.
              </p>

            </div>


            {/* TIMELINE */}

            <div className="mx-auto mt-14 max-w-5xl">

              <div className="relative">

                <div className="absolute left-[28px] top-8 bottom-8 hidden w-px bg-[#D5DEEB] md:block" />

                <div className="space-y-6">

                  {evolutionSteps.map((step) => (
                    <div
                      key={step.number}
                      className="scroll-reveal-item relative flex gap-5 rounded-2xl border border-[#DCE4EF] bg-white p-6 md:gap-7 md:p-7"
                    >

                      <div className="relative z-10 flex h-14 w-14 flex-shrink-0 items-center justify-center rounded-2xl bg-[#173B8F] text-white shadow-sm">

                        <step.icon className="h-6 w-6" />

                      </div>

                      <div className="flex-1">

                        <div className="flex flex-wrap items-center gap-3">

                          <span className="text-xs font-bold tracking-[0.15em] text-[#173B8F]">
                            {step.number}
                          </span>

                          <h3 className="text-xl font-bold text-[#102A66]">
                            {step.title}
                          </h3>

                        </div>

                        <p className="mt-2 leading-relaxed text-[#52627A]">
                          {step.text}
                        </p>

                      </div>

                    </div>
                  ))}

                </div>

              </div>

            </div>

          </div>

        </section>


        {/* ========================================================
            GARANTÍA
            ======================================================== */}

        <section
          id="garantia"
          className="relative bg-white py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-[#F4F6F9] before:to-white"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-3xl text-center">

              <p className="scroll-reveal-item text-sm font-bold uppercase tracking-[0.16em] text-[#173B8F]">
                Garantía Modira
              </p>

              <h2 className="scroll-reveal-item mt-3 text-3xl font-bold text-[#102A66] md:text-4xl">
                Seguimos detrás de lo que implementamos
              </h2>

              <p className="scroll-reveal-item mt-4 text-[#52627A] md:text-lg">
                Una automatización debe funcionar correctamente una vez
                implantada. Por eso ofrecemos una garantía sobre los errores de
                funcionamiento directamente atribuibles a nuestra
                implementación.
              </p>

            </div>


            {/* GARANTÍA PRINCIPAL */}

            <div className="scroll-reveal-item mx-auto mt-12 max-w-5xl overflow-hidden rounded-3xl bg-gradient-to-r from-[#102A66] to-[#173B8F] text-white shadow-lg">

              <div className="grid md:grid-cols-[0.8fr_1.2fr]">

                <div className="flex flex-col items-center justify-center border-b border-white/10 p-8 text-center md:border-b-0 md:border-r md:p-10">

                  <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-white/10">

                    <BadgeCheck className="h-8 w-8" />

                  </div>

                  <p className="mt-5 text-sm font-semibold uppercase tracking-[0.15em] text-white/60">
                    Garantía
                  </p>

                  <p className="mt-2 text-5xl font-bold">
                    90
                  </p>

                  <p className="mt-1 text-lg text-white/80">
                    días
                  </p>

                </div>


                <div className="p-8 md:p-10">

                  <h3 className="text-2xl font-bold">
                    Corrección de errores de implementación
                  </h3>

                  <p className="mt-4 leading-relaxed text-white/75">
                    Modira garantiza durante 90 días la corrección, sin coste
                    adicional, de errores de funcionamiento directamente
                    atribuibles a la implementación realizada por Modira.
                  </p>

                  <div className="mt-7 grid gap-3 sm:grid-cols-2">

                    {[
                      "Errores directamente atribuibles a la implementación.",
                      "Corrección durante el periodo de garantía.",
                      "Sin coste adicional cuando corresponda a la garantía.",
                      "Soporte y mantenimiento disponibles de forma adicional.",
                    ].map((item) => (
                      <div
                        key={item}
                        className="flex items-start gap-3 rounded-xl bg-white/10 p-4"
                      >

                        <CheckCircle2 className="mt-0.5 h-5 w-5 flex-shrink-0" />

                        <span className="text-sm leading-relaxed text-white/80">
                          {item}
                        </span>

                      </div>
                    ))}

                  </div>

                </div>

              </div>

            </div>


            {/* FLUJO */}

            <div className="mx-auto mt-8 max-w-5xl">

              <div className="grid gap-4 md:grid-cols-4">

                {[
                  {
                    icon: Wrench,
                    title: "Implementamos",
                    text: "Construimos y ponemos en funcionamiento la solución acordada.",
                  },
                  {
                    icon: CheckCircle2,
                    title: "Comprobamos",
                    text: "Verificamos el funcionamiento antes de finalizar.",
                  },
                  {
                    icon: BadgeCheck,
                    title: "Garantizamos",
                    text: "90 días para errores directamente atribuibles a nuestra implementación.",
                  },
                  {
                    icon: LifeBuoy,
                    title: "Acompañamos",
                    text: "Puedes contratar soporte y mantenimiento para continuar evolucionando.",
                  },
                ].map((item) => (
                  <div
                    key={item.title}
                    className="scroll-reveal-item rounded-2xl border border-[#DCE4EF] bg-[#F8FAFC] p-6 text-center"
                  >

                    <div className="mx-auto flex h-11 w-11 items-center justify-center rounded-xl bg-[#173B8F]/10 text-[#173B8F]">

                      <item.icon className="h-5 w-5" />

                    </div>

                    <h3 className="mt-4 font-bold text-[#102A66]">
                      {item.title}
                    </h3>

                    <p className="mt-2 text-sm leading-relaxed text-[#52627A]">
                      {item.text}
                    </p>

                  </div>
                ))}

              </div>

            </div>


            <div className="scroll-reveal-item mx-auto mt-6 max-w-4xl rounded-2xl border border-[#DCE4EF] bg-[#F4F6F9] p-5 text-center">

              <p className="text-xs leading-relaxed text-[#8793A5]">
                La garantía se refiere a errores de funcionamiento directamente
                atribuibles a la implementación realizada por Modira y está
                sujeta a las condiciones específicas del servicio contratado.
              </p>

            </div>

          </div>

        </section>


        {/* ========================================================
            VISIÓN
            ======================================================== */}

        <section
          className="relative bg-[#F4F6F9] py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-white before:to-[#F4F6F9]"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="scroll-reveal-item mx-auto max-w-5xl rounded-3xl bg-gradient-to-r from-[#102A66] to-[#173B8F] px-7 py-12 text-white md:px-14 md:py-16">

              <div className="mx-auto max-w-3xl text-center">

                <p className="text-sm font-bold uppercase tracking-[0.16em] text-white/60">
                  Nuestra visión
                </p>

                <h2 className="mt-3 text-3xl font-bold md:text-4xl">
                  Construir sistemas que crezcan junto a las empresas
                </h2>

                <p className="mt-5 text-base leading-relaxed text-white/80 md:text-lg">
                  Nuestro objetivo no es implementar una automatización y
                  desaparecer. Queremos construir soluciones digitales que
                  puedan evolucionar a medida que también evolucionan las
                  empresas que confían en nosotros.
                </p>


                <div className="mt-8 grid gap-4 text-left sm:grid-cols-3">

                  {[
                    "Tecnología útil",
                    "Procesos eficientes",
                    "Relaciones a largo plazo",
                  ].map((item) => (
                    <div
                      key={item}
                      className="flex items-center gap-2 rounded-xl bg-white/10 p-4"
                    >

                      <CircleCheck className="h-5 w-5 flex-shrink-0" />

                      <span className="text-sm font-semibold">
                        {item}
                      </span>

                    </div>
                  ))}

                </div>

              </div>

            </div>

          </div>

        </section>


        {/* ========================================================
            CTA
            ======================================================== */}

        <section
          id="auditoria"
          className="relative bg-white py-16 md:py-24 before:absolute before:inset-x-0 before:top-0 before:h-8 before:bg-gradient-to-b before:from-[#F4F6F9] before:to-white"
        >

          <div className="container mx-auto px-6 sm:px-8 lg:px-12 xl:px-16">

            <div className="mx-auto max-w-4xl text-center">

              <div className="scroll-reveal-item mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-[#173B8F]/10">

  <img
    src={import.meta.env.VITE_APP_LOGO_DARK}
    alt="Logo de Modira"
    className="h-9 w-auto object-contain"
  />

</div>

              <h2 className="scroll-reveal-item mt-5 text-3xl font-bold text-[#102A66] md:text-4xl">
                ¿Y si parte del trabajo de tu empresa pudiera hacerse solo?
              </h2>

              <p className="scroll-reveal-item mx-auto mt-4 max-w-2xl text-[#52627A] md:text-lg">
                Cuéntanos cómo funciona actualmente tu empresa y analizaremos
                dónde puede existir una oportunidad real de automatización.
              </p>


              <div className="scroll-reveal-item mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">

                <button
                  type="button"
                  onClick={() => {
                    setLocation("/");

                    setTimeout(() => {
                      document
                        .getElementById("auditoria")
                        ?.scrollIntoView({
                          behavior: "smooth",
                        });
                    }, 100);
                  }}
                  className="inline-flex items-center gap-2 rounded-lg bg-[#173B8F] px-7 py-3.5 font-semibold text-white shadow-sm transition hover:bg-[#102A66]"
                >
                  Solicitar auditoría gratuita
                  <ArrowRight className="h-4 w-4" />
                </button>


                <button
                  type="button"
                  onClick={() => setLocation("/como-trabajamos")}
                  className="inline-flex items-center gap-2 rounded-lg border border-[#D5DEEB] bg-white px-7 py-3.5 font-semibold text-[#173B8F] transition hover:border-[#173B8F] hover:bg-[#F4F6F9]"
                >
                  Ver cómo trabajamos
                  <ArrowRight className="h-4 w-4" />
                </button>

              </div>


              <p className="scroll-reveal-item mt-4 text-sm text-[#8793A5]">
                Sin compromiso. Analizamos tu caso y te explicamos las
                posibilidades.
              </p>

            </div>

          </div>

        </section>

      </main>


      {/* ========================================================
          FOOTER
          ======================================================== */}

      <footer className="bg-[#102A66] py-8 text-white">

        <div className="container mx-auto px-4 text-center text-sm text-white/60">
          © {new Date().getFullYear()} Modira. Todos los derechos reservados.
        </div>

      </footer>

    </div>
  );
}


/*
 * ============================================================
 * ICONOS AUXILIARES
 *
 * Se mantienen como componentes simples para no depender de
 * nombres que puedan variar entre versiones de lucide-react.
 * ============================================================
 */

function LightbulbIcon(props: React.ComponentProps<typeof Sparkles>) {
  return <Sparkles {...props} />;
}

function AlertTriangleIcon(
  props: React.ComponentProps<typeof ShieldCheck>
) {
  return <ShieldCheck {...props} />;
}

function MessageSquareIcon(
  props: React.ComponentProps<typeof LifeBuoy>
) {
  return <LifeBuoy {...props} />;
}

function DatabaseIcon(
  props: React.ComponentProps<typeof Layers3>
) {
  return <Layers3 {...props} />;
}

function CloudIcon(
  props: React.ComponentProps<typeof Layers3>
) {
  return <Layers3 {...props} />;
}