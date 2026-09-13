import { useEffect, useState } from "react";
import Header from "@/components/Header";
import {
  ArrowLeft,
  CheckCircle2,
  BarChart3,
  ShieldCheck,
  Settings2,
  Cookie,
} from "lucide-react";
import { useLocation } from "wouter";

export default function CookiePolicy() {
  const [, setLocation] = useLocation();
  const [isScrolled, setIsScrolled] = useState(false);

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
              Política de Cookies
            </h1>

            <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
              Información sobre las cookies y tecnologías similares
              utilizadas en la web de Modira, sus finalidades y la
              gestión de las preferencias del usuario.
            </p>

            <div className="mt-6 text-sm text-gray-400">
              Última actualización: Septiembre de 2026
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

                {/* ==================================================
                    1. ¿QUÉ SON LAS COOKIES?
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    1. ¿Qué son las cookies?
                  </h2>

                  <p className="text-gray-600 leading-8">
                    Las cookies son pequeños archivos o identificadores que
                    pueden almacenarse en el dispositivo del usuario cuando
                    visita un sitio web y que permiten, entre otras funciones,
                    recordar determinada información, mantener funcionalidades
                    técnicas o recopilar información sobre el uso del sitio.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    Esta Política también se refiere, cuando resulte aplicable,
                    a otras tecnologías de almacenamiento o acceso a
                    información en el dispositivo del usuario, como el
                    almacenamiento local (
                    <code className="px-1.5 py-0.5 rounded bg-gray-100 text-gray-700 text-sm">
                      localStorage
                    </code>
                    ), cuando Modira las utilice.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La utilización de dispositivos de almacenamiento y
                    recuperación de datos en equipos terminales se encuentra
                    regulada, entre otras normas, por el artículo 22.2 de la
                    Ley 34/2002, de 11 de julio, de Servicios de la Sociedad
                    de la Información y del Comercio Electrónico (LSSI).
                    Cuando estas tecnologías no sean estrictamente necesarias
                    para prestar el servicio solicitado o para la transmisión
                    de una comunicación, su utilización estará sujeta a los
                    requisitos de información y consentimiento establecidos por
                    la normativa aplicable.
                  </p>
                </section>

                {/* ==================================================
                    2. TECNOLOGÍAS UTILIZADAS
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-6">
                    2. Tecnologías utilizadas por Modira
                  </h2>

                  <p className="text-gray-600 leading-8 mb-8">
                    Modira utiliza tecnologías de almacenamiento y acceso a
                    información en el dispositivo del usuario con distintas
                    finalidades.
                  </p>

                  {/* Necesarias */}

                  <div className="border border-gray-200 rounded-xl p-6 md:p-7 mb-5">
                    <div className="flex items-start gap-4">
                      <div className="flex-shrink-0 w-10 h-10 rounded-lg bg-[#EFF6FF] flex items-center justify-center">
                        <ShieldCheck
                          size={20}
                          className="text-[#1E3A8A]"
                        />
                      </div>

                      <div className="flex-1">
                        <h3 className="text-lg md:text-xl font-semibold text-[#1E3A8A] mb-3">
                          2.1. Tecnologías necesarias para el funcionamiento
                        </h3>

                        <p className="text-gray-600 leading-7">
                          Modira utiliza determinadas tecnologías necesarias
                          para permitir el funcionamiento técnico de la web y
                          de determinadas funcionalidades solicitadas por el
                          usuario.
                        </p>

                        <p className="text-gray-600 leading-7 mt-4">
                          Entre ellas se encuentra el almacenamiento local
                          utilizado para conservar las preferencias
                          seleccionadas por el usuario en el sistema de gestión
                          de cookies.
                        </p>

                        <p className="text-gray-600 leading-7 mt-4">
                          Asimismo, determinadas funcionalidades de Modira
                          pueden utilizar almacenamiento del navegador para
                          mantener información técnica necesaria para su
                          funcionamiento.
                        </p>

                        <div className="mt-5 pt-4 border-t border-gray-100">
                          <p className="text-sm text-gray-500 leading-6">
                            Estas tecnologías no se utilizan con fines
                            publicitarios.
                          </p>
                        </div>
                      </div>
                    </div>
                  </div>

                  {/* GA4 */}

                  <div className="border border-gray-200 rounded-xl p-6 md:p-7 mb-5">
                    <div className="flex items-start gap-4">
                      <div className="flex-shrink-0 w-10 h-10 rounded-lg bg-[#F5F7FA] flex items-center justify-center">
                        <BarChart3
                          size={20}
                          className="text-[#1E3A8A]"
                        />
                      </div>

                      <div className="flex-1">
                        <h3 className="text-lg md:text-xl font-semibold text-[#1E3A8A] mb-3">
                          2.2. Google Analytics 4
                        </h3>

                        <p className="text-gray-600 leading-7">
                          Modira utiliza{" "}
                          <strong>Google Analytics 4 (GA4)</strong> como
                          herramienta de analítica web.
                        </p>

                        <p className="text-gray-600 leading-7 mt-4">
                          Google Analytics se utiliza para obtener información
                          estadística sobre el uso del sitio web y comprender
                          cómo interactúan los usuarios con él.
                        </p>

                        <p className="text-gray-600 leading-7 mt-4">
                          Entre la información que Google Analytics puede
                          recopilar mediante su configuración estándar se
                          encuentran datos como el número de usuarios,
                          estadísticas de sesión, ubicación geográfica
                          aproximada e información sobre el navegador y el
                          dispositivo.
                        </p>

                        <p className="text-gray-600 leading-7 mt-4">
                          La activación de Google Analytics en Modira está
                          condicionada a la aceptación de la categoría de
                          analítica mediante el mecanismo de gestión de
                          preferencias habilitado en el sitio web.
                        </p>

                        <div className="mt-5 bg-[#F8FAFC] border border-gray-100 rounded-lg p-4">
                          <p className="text-sm text-gray-500 leading-6">
                            Modira no carga Google Analytics antes de que el
                            usuario haya realizado la acción correspondiente de
                            aceptación de la analítica.
                          </p>
                        </div>
                      </div>
                    </div>
                  </div>

                  {/* Marketing */}

                  <div className="border border-gray-200 rounded-xl p-6 md:p-7">
                    <div className="flex items-start gap-4">
                      <div className="flex-shrink-0 w-10 h-10 rounded-lg bg-[#F5F7FA] flex items-center justify-center">
                        <Settings2
                          size={20}
                          className="text-[#1E3A8A]"
                        />
                      </div>

                      <div className="flex-1">
                        <h3 className="text-lg md:text-xl font-semibold text-[#1E3A8A] mb-3">
                          2.3. Tecnologías de marketing
                        </h3>

                        <p className="text-gray-600 leading-7">
                          Actualmente Modira{" "}
                          <strong>
                            no utiliza tecnologías de marketing, publicidad
                            comportamental o remarketing
                          </strong>{" "}
                          dentro de la configuración descrita en esta
                          Política.
                        </p>

                        <p className="text-gray-600 leading-7 mt-4">
                          En consecuencia, Modira no utiliza actualmente
                          cookies específicas de marketing o publicidad para
                          esta finalidad.
                        </p>
                      </div>
                    </div>
                  </div>
                </section>

                {/* ==================================================
                    3. DETALLE DE LAS TECNOLOGÍAS
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    3. Detalle de las tecnologías
                  </h2>

                  <p className="text-gray-600 leading-8 mb-6">
                    La siguiente tabla recoge las principales tecnologías de
                    almacenamiento utilizadas actualmente por Modira y su
                    finalidad.
                  </p>

                  <div className="overflow-x-auto rounded-xl border border-gray-200">
                    <table className="w-full min-w-[720px] text-left">
                      <thead className="bg-[#F8FAFC]">
                        <tr>
                          <th className="px-5 py-4 text-sm font-semibold text-[#1E3A8A] border-b border-gray-200">
                            Tecnología
                          </th>

                          <th className="px-5 py-4 text-sm font-semibold text-[#1E3A8A] border-b border-gray-200">
                            Tipo
                          </th>

                          <th className="px-5 py-4 text-sm font-semibold text-[#1E3A8A] border-b border-gray-200">
                            Finalidad
                          </th>

                          <th className="px-5 py-4 text-sm font-semibold text-[#1E3A8A] border-b border-gray-200">
                            Consentimiento
                          </th>
                        </tr>
                      </thead>

                      <tbody className="divide-y divide-gray-100">
                        <tr>
                          <td className="px-5 py-4 text-sm text-gray-600">
                            <code className="px-1.5 py-0.5 rounded bg-gray-100 text-gray-700">
                              cookiePreferences
                            </code>
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            localStorage
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            Guardar la preferencia del usuario respecto de las
                            tecnologías opcionales.
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            No
                          </td>
                        </tr>

                        <tr>
                          <td className="px-5 py-4 text-sm text-gray-600">
                            <code className="px-1.5 py-0.5 rounded bg-gray-100 text-gray-700">
                              _ga
                            </code>
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            Cookie de Google Analytics 4
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            Distinguir usuarios para fines de analítica.
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            Sí
                          </td>
                        </tr>

                        <tr>
                          <td className="px-5 py-4 text-sm text-gray-600">
                            <code className="px-1.5 py-0.5 rounded bg-gray-100 text-gray-700">
                              _ga_&lt;container-id&gt;
                            </code>
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            Cookie de Google Analytics 4
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            Mantener el estado de la sesión de analítica.
                          </td>

                          <td className="px-5 py-4 text-sm text-gray-600">
                            Sí
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <p className="text-sm text-gray-500 leading-6 mt-5">
                    Las cookies de Google Analytics solo se utilizan cuando la
                    categoría de analítica ha sido aceptada.
                  </p>

                  <p className="text-sm text-gray-500 leading-6 mt-3">
                    Los nombres y características concretas de las cookies de
                    terceros pueden variar si el proveedor modifica su
                    funcionamiento o si cambia la configuración técnica de
                    Modira. Google identifica actualmente{" "}
                    <code className="px-1 py-0.5 rounded bg-gray-100 text-gray-700">
                      _ga
                    </code>{" "}
                    y{" "}
                    <code className="px-1 py-0.5 rounded bg-gray-100 text-gray-700">
                      _ga_&lt;container-id&gt;
                    </code>{" "}
                    como las cookies principales utilizadas por sus etiquetas
                    JavaScript de GA4.
                  </p>
                </section>

                {/* ==================================================
                    4. GESTIÓN DEL CONSENTIMIENTO
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    4. Gestión del consentimiento
                  </h2>

                  <p className="text-gray-600 leading-8 mb-5">
                    Cuando sea necesario obtener el consentimiento para
                    utilizar determinadas tecnologías, Modira mostrará un
                    mecanismo de gestión de preferencias que permitirá al
                    usuario decidir sobre su utilización.
                  </p>

                  <p className="text-gray-600 leading-8 mb-5">
                    El usuario podrá:
                  </p>

                  <ul className="space-y-3 text-gray-600 mb-6">
                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>aceptar la analítica;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>rechazar la analítica;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>
                        consultar y configurar sus preferencias.
                      </span>
                    </li>
                  </ul>

                  <p className="text-gray-600 leading-8">
                    La analítica no se activará antes de que el usuario haya
                    prestado el consentimiento correspondiente.
                  </p>

                  <div className="mt-6 bg-[#F8FAFC] border border-gray-200 rounded-xl p-6">
                    <p className="text-gray-600 leading-7">
                      La Agencia Española de Protección de Datos establece que
                      las opciones de aceptar y rechazar deben ofrecerse al
                      mismo tiempo, al mismo nivel y con la misma visibilidad.
                    </p>

                    <p className="text-gray-600 leading-7 mt-4">
                      El consentimiento para las tecnologías que lo requieran
                      deberá prestarse mediante una acción afirmativa del
                      usuario y después de haber recibido información clara
                      sobre su utilización y finalidad.
                    </p>
                  </div>
                </section>

                {/* ==================================================
                    5. ALMACENAMIENTO DE LAS PREFERENCIAS
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    5. Almacenamiento de las preferencias
                  </h2>

                  <p className="text-gray-600 leading-8">
                    Las preferencias seleccionadas por el usuario se almacenan
                    localmente en el dispositivo mediante{" "}
                    <code className="px-1.5 py-0.5 rounded bg-gray-100 text-gray-700">
                      localStorage
                    </code>
                    .
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La clave utilizada actualmente por el sistema de gestión
                    de preferencias es:
                  </p>

                  <div className="mt-4 inline-block bg-[#F8FAFC] border border-gray-200 rounded-lg px-4 py-3">
                    <code className="text-sm text-[#1E3A8A]">
                      cookiePreferences
                    </code>
                  </div>

                  <p className="text-gray-600 leading-8 mt-5">
                    Esta información permite a Modira recordar la decisión
                    adoptada por el usuario y evitar solicitarla nuevamente
                    durante cada navegación.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    El almacenamiento de esta preferencia tiene una finalidad
                    exclusivamente relacionada con la gestión de las propias
                    preferencias del usuario y no constituye una herramienta
                    de analítica ni de publicidad.
                  </p>
                </section>

                {/* ==================================================
                    6. GOOGLE ANALYTICS 4
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    6. Google Analytics 4 y cookies de analítica
                  </h2>

                  <p className="text-gray-600 leading-8">
                    Cuando el usuario acepta la categoría de analítica, Modira
                    carga la tecnología de Google Analytics 4 y permite que
                    esta establezca las cookies necesarias para realizar la
                    medición.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    Google Analytics utiliza cookies propias para distinguir
                    usuarios y sesiones. Google documenta actualmente las
                    siguientes cookies principales:
                  </p>

                  <ul className="space-y-3 text-gray-600 mt-5">
                    <li className="flex items-start gap-3">
                      <span className="text-[#1E3A8A] font-semibold">01</span>

                      <span>
                        <code className="px-1.5 py-0.5 rounded bg-gray-100 text-gray-700">
                          _ga
                        </code>
                        : utilizada para distinguir usuarios.
                      </span>
                    </li>

                    <li className="flex items-start gap-3">
                      <span className="text-[#1E3A8A] font-semibold">02</span>

                      <span>
                        <code className="px-1.5 py-0.5 rounded bg-gray-100 text-gray-700">
                          _ga_&lt;container-id&gt;
                        </code>
                        : utilizada para mantener el estado de la sesión.
                      </span>
                    </li>
                  </ul>

                  <p className="text-gray-600 leading-8 mt-5">
                    La duración predeterminada indicada por Google para ambas
                    es de dos años, aunque esta duración puede modificarse
                    mediante la configuración de Google Analytics.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La información generada mediante Google Analytics es
                    tratada por Google de acuerdo con sus propias condiciones
                    y políticas aplicables.
                  </p>
                </section>

                {/* ==================================================
                    7. FINALIDAD DE LA ANALÍTICA
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    7. Finalidad de la analítica
                  </h2>

                  <p className="text-gray-600 leading-8">
                    La utilización de Google Analytics tiene como finalidad
                    obtener información estadística sobre el funcionamiento y
                    utilización del sitio web.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    Esta información puede utilizarse para conocer, entre
                    otros aspectos:
                  </p>

                  <ul className="space-y-3 text-gray-600 mt-5">
                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>el número de usuarios;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>las sesiones;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>la interacción con el sitio web;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>
                        las características generales del navegador y
                        dispositivo utilizados;
                      </span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>la ubicación geográfica aproximada;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>
                        el comportamiento general de navegación y utilización
                        del sitio, en la medida en que las funcionalidades de
                        medición configuradas en Google Analytics lo permitan.
                      </span>
                    </li>
                  </ul>

                  <p className="text-sm text-gray-500 leading-6 mt-6">
                    Google indica que la implementación estándar de Analytics
                    recopila información como usuarios, estadísticas de sesión,
                    ubicación aproximada e información del navegador y
                    dispositivo.
                  </p>
                </section>

                {/* ==================================================
                    8. AUSENCIA DE PUBLICIDAD Y MARKETING
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    8. Ausencia de tecnologías de publicidad y marketing
                  </h2>

                  <p className="text-gray-600 leading-8">
                    En la configuración actual de Modira no se utilizan
                    tecnologías destinadas a:
                  </p>

                  <ul className="space-y-3 text-gray-600 mt-5">
                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>publicidad comportamental;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>remarketing;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>
                        seguimiento publicitario mediante píxeles;
                      </span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>cookies de publicidad de terceros;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>perfiles publicitarios.</span>
                    </li>
                  </ul>

                  <div className="mt-6 bg-[#F8FAFC] border border-gray-200 rounded-xl p-6">
                    <p className="text-gray-600 leading-7">
                      La presente Política deberá actualizarse si en el futuro
                      se incorporan tecnologías con estas finalidades.
                    </p>
                  </div>
                </section>

                {/* ==================================================
                    9. TECNOLOGÍAS DE TERCEROS
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    9. Tecnologías de terceros
                  </h2>

                  <p className="text-gray-600 leading-8">
                    Google Analytics es actualmente el único servicio de
                    terceros utilizado por Modira específicamente para realizar
                    analítica web mediante tecnologías de almacenamiento en el
                    dispositivo.
                  </p>

                  <div className="mt-6 border border-gray-200 rounded-xl p-6">
                    <div className="flex items-start gap-4">
                      <div className="flex-shrink-0 w-10 h-10 rounded-lg bg-[#EFF6FF] flex items-center justify-center">
                        <BarChart3
                          size={20}
                          className="text-[#1E3A8A]"
                        />
                      </div>

                      <div>
                        <h3 className="font-semibold text-[#1E3A8A] mb-2">
                          Google Analytics
                        </h3>

                        <p className="text-gray-600 leading-7">
                          Google Analytics es un servicio proporcionado por
                          Google.
                        </p>

                        <p className="text-gray-600 leading-7 mt-3">
                          La utilización de este servicio puede implicar el
                          tratamiento de información por parte de Google
                          conforme a sus propias condiciones y políticas.
                        </p>
                      </div>
                    </div>
                  </div>

                  <p className="text-gray-600 leading-7 mt-5">
                    La información sobre el funcionamiento de las cookies de
                    Google Analytics puede consultarse en la documentación
                    oficial de Google Analytics.
                  </p>
                </section>

                {/* ==================================================
                    10. MODIFICACIÓN O RETIRADA
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    10. Modificación o retirada del consentimiento
                  </h2>

                  <p className="text-gray-600 leading-8">
                    El usuario podrá modificar posteriormente su decisión sobre
                    las tecnologías que requieren consentimiento mediante el
                    mecanismo de gestión de preferencias disponible en el
                    sitio web.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    Cuando el usuario retire su consentimiento para la
                    analítica, Modira dejará de activar Google Analytics
                    conforme a la configuración de su sistema de gestión de
                    preferencias.
                  </p>

                  <div className="mt-6 bg-[#F8FAFC] border border-gray-200 rounded-xl p-6">
                    <p className="text-gray-600 leading-7">
                      La retirada del consentimiento no afectará a la licitud
                      de los tratamientos realizados con anterioridad a dicha
                      retirada.
                    </p>
                  </div>
                </section>

                {/* ==================================================
                    11. TECNOLOGÍAS ESTRICTAMENTE NECESARIAS
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    11. Tecnologías estrictamente necesarias
                  </h2>

                  <p className="text-gray-600 leading-8">
                    Determinadas tecnologías pueden utilizarse sin
                    consentimiento cuando sean estrictamente necesarias para:
                  </p>

                  <ul className="space-y-3 text-gray-600 mt-5">
                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>
                        efectuar la transmisión de una comunicación por una red
                        de comunicaciones electrónicas;
                      </span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>
                        prestar un servicio expresamente solicitado por el
                        usuario;
                      </span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>
                        permitir el funcionamiento técnico de determinadas
                        funcionalidades.
                      </span>
                    </li>
                  </ul>

                  <p className="text-gray-600 leading-8 mt-5">
                    El artículo 22.2 de la LSSI contempla esta excepción para el
                    almacenamiento o acceso técnicamente necesario para la
                    transmisión de comunicaciones o para la prestación de un
                    servicio de la sociedad de la información expresamente
                    solicitado.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La AEPD también reconoce determinadas cookies técnicas o
                    necesarias como exceptuadas del requisito de consentimiento,
                    aunque recomienda informar de ellas por razones de
                    transparencia.
                  </p>
                </section>

                {/* ==================================================
                    12. CONFIGURACIÓN DEL NAVEGADOR
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    12. Configuración del navegador
                  </h2>

                  <p className="text-gray-600 leading-8">
                    El usuario puede configurar su navegador para bloquear,
                    eliminar o limitar determinadas cookies y otras tecnologías
                    de almacenamiento.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La desactivación de tecnologías estrictamente necesarias
                    puede afectar al funcionamiento de determinadas
                    funcionalidades del sitio web.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La gestión realizada mediante el navegador es independiente
                    del sistema de preferencias proporcionado por Modira.
                  </p>
                </section>

                {/* ==================================================
                    13. PROTECCIÓN DE DATOS PERSONALES
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    13. Protección de datos personales
                  </h2>

                  <p className="text-gray-600 leading-8">
                    Algunas cookies o tecnologías similares pueden implicar el
                    tratamiento de datos personales.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La información completa sobre los tratamientos de datos
                    personales realizados por Modira, incluyendo las
                    finalidades, bases jurídicas, destinatarios, conservación,
                    transferencias internacionales y derechos de los
                    interesados, se encuentra en la{" "}
                    <strong>Política de Privacidad</strong>.
                  </p>

                  <div className="mt-6 bg-[#F8FAFC] border border-gray-200 rounded-xl p-6">
                    <p className="text-gray-600 leading-7">
                      La Política de Cookies no sustituye a la Política de
                      Privacidad.
                    </p>
                  </div>
                </section>

                {/* ==================================================
                    14. ACTUALIZACIÓN
                    ================================================== */}

                <section className="pb-10 mb-10 border-b border-gray-100">
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    14. Actualización de la Política de Cookies
                  </h2>

                  <p className="text-gray-600 leading-8">
                    Modira podrá actualizar esta Política cuando se produzcan
                    cambios en:
                  </p>

                  <ul className="space-y-3 text-gray-600 mt-5">
                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>las tecnologías utilizadas;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>las cookies utilizadas;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>los servicios de terceros;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>las finalidades del tratamiento;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>la configuración técnica del sitio web;</span>
                    </li>

                    <li className="flex items-start gap-3">
                      <CheckCircle2
                        size={18}
                        className="text-[#1E3A8A] mt-1 flex-shrink-0"
                      />
                      <span>la normativa aplicable.</span>
                    </li>
                  </ul>

                  <p className="text-gray-600 leading-8 mt-5">
                    Cuando se incorporen nuevas tecnologías que requieran
                    consentimiento, estas deberán incorporarse al
                    correspondiente sistema de gestión de preferencias antes
                    de su utilización.
                  </p>

                  <p className="text-gray-600 leading-8 mt-4">
                    La fecha de actualización indicada al comienzo de esta
                    Política reflejará su versión vigente.
                  </p>
                </section>

                {/* ==================================================
                    15. CONTACTO
                    ================================================== */}

                <section>
                  <h2 className="text-2xl md:text-3xl font-bold text-[#1E3A8A] mb-5">
                    15. Contacto
                  </h2>

                  <p className="text-gray-600 leading-8 mb-6">
                    Para cualquier cuestión relacionada con esta Política de
                    Cookies puede contactar con Modira mediante:
                  </p>

                  <div className="bg-[#F8FAFC] border border-gray-200 rounded-xl p-6 md:p-7">
                    <div className="space-y-4">
                      <p className="text-gray-600">
                        <strong className="text-[#1E3A8A]">
                          Correo electrónico:
                        </strong>{" "}
                        contacto@modira.com
                      </p>

                      <p className="text-gray-600">
                        <strong className="text-[#1E3A8A]">
                          Titular:
                        </strong>{" "}
                        [NOMBRE / RAZÓN SOCIAL]
                      </p>

                      <p className="text-gray-600">
                        <strong className="text-[#1E3A8A]">
                          Asunto:
                        </strong>{" "}
                        Política de Cookies
                      </p>
                    </div>
                  </div>
                </section>
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