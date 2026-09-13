import { useEffect, useState } from "react";
import Header from "@/components/Header";
import { ArrowLeft, FileText, CheckCircle2, ChevronDown } from "lucide-react";

type Block =
  | { type: "p"; text: string }
  | { type: "list"; items: string[] }
  | { type: "highlight" | "quote" | "sub" | "example"; text: string }
  | { type: "process"; items: string[] }
  | { type: "doc" | "contact" | "meta"; title: string; text: string };

type Section = {
  id: string;
  number: string;
  title: string;
  blocks: Block[];
};

const sections: Section[] = [
  { id: `objeto`, number: `1`, title: `OBJETO DE ESTAS CONDICIONES`, blocks: [{ type: "p", text: `Las presentes Condiciones regulan la solicitud y realización de la Auditoría Gratuita de MODIRA.` }, { type: "p", text: `La auditoría constituye un análisis inicial de la situación, procesos o necesidades planteadas por la persona solicitante, con el objetivo de identificar posibles oportunidades de:` }, { type: "list", items: [`automatización;`, `mejora de procesos;`, `reducción de tareas manuales;`, `optimización de determinadas operaciones;`, `integración entre herramientas;`, `utilización de soluciones tecnológicas;`, `mejora de la eficiencia o funcionamiento.`] }, { type: "p", text: `La auditoría podrá adaptarse a las características de cada empresa y a la información facilitada por la persona solicitante.` }, { type: "p", text: `Estas condiciones complementan los Términos y Condiciones de MODIRA y deben interpretarse conjuntamente con ellos.` }] },
  { id: `gratuita`, number: `2`, title: `LA AUDITORÍA ES REALMENTE GRATUITA`, blocks: [{ type: "p", text: `La solicitud y realización de la auditoría inicial ofrecida por MODIRA no tiene coste para la persona solicitante.` }, { type: "p", text: `La realización de la auditoría no genera:` }, { type: "list", items: [`una cuota;`, `una suscripción;`, `una obligación de permanencia;`, `una obligación de contratación;`, `una obligación de aceptar posteriormente un presupuesto;`, `ni ninguna otra obligación económica derivada únicamente de haber solicitado o recibido la auditoría.`] }, { type: "highlight", text: `No existe ningún pago posterior automático por el hecho de haber realizado la auditoría.` }, { type: "p", text: `Si posteriormente se propone la contratación de un servicio de MODIRA, dicha contratación constituirá una relación independiente y deberá contar con las condiciones económicas correspondientes y con la aceptación del presupuesto, propuesta o documento contractual aplicable.` }, { type: "p", text: `Los Términos de MODIRA establecen que el inicio de un proyecto no implica por sí mismo una contratación ni genera automáticamente una obligación de pago.` }] },
  { id: `que-recibes`, number: `3`, title: `¿QUÉ RECIBES AL SOLICITARLA?`, blocks: [{ type: "p", text: `La auditoría está pensada para que MODIRA pueda entender mejor:` }, { type: "list", items: [`cómo funciona actualmente la empresa;`, `qué proceso se quiere mejorar;`, `qué tareas pueden estar generando trabajo innecesario;`, `dónde pueden existir oportunidades de automatización;`, `qué herramientas se utilizan actualmente;`, `qué problema concreto se quiere resolver;`, `y qué tipo de solución podría tener sentido en cada caso.`] }, { type: "p", text: `El análisis se realizará sobre la información proporcionada por la persona solicitante y, cuando sea necesario, sobre información adicional obtenida durante la comunicación relacionada con la auditoría.` }, { type: "p", text: `La profundidad del análisis dependerá de las características de cada caso. No todas las empresas presentan las mismas necesidades y, por tanto, no todas las auditorías tendrán necesariamente el mismo alcance.` }] },
  { id: `no-promete`, number: `4`, title: `LO QUE LA AUDITORÍA NO PROMETE`, blocks: [{ type: "p", text: `La auditoría es un análisis inicial y no constituye una garantía de resultados concretos.` }, { type: "p", text: `Por tanto, la realización de la auditoría no garantiza:` }, { type: "list", items: [`un número determinado de automatizaciones;`, `un ahorro económico concreto;`, `un ahorro de tiempo determinado;`, `que un proceso concreto pueda automatizarse;`, `que exista una solución tecnológica adecuada para cada necesidad planteada;`, `que MODIRA pueda implementar todas las mejoras identificadas;`, `que posteriormente se realice un presupuesto;`, `que el presupuesto, si se realiza, sea aceptado;`, `ni que finalmente exista una relación contractual entre MODIRA y la empresa solicitante.`] }, { type: "p", text: `Esta delimitación coincide con la regulación de los Términos de MODIRA sobre la auditoría inicial gratuita.` }] },
  { id: `no-obliga`, number: `5`, title: `LA AUDITORÍA NO OBLIGA A CONTRATAR`, blocks: [{ type: "p", text: `La persona solicitante puede solicitar la auditoría, recibir el análisis y decidir no continuar.` }, { type: "p", text: `MODIRA podrá, cuando resulte apropiado, presentar posteriormente una propuesta de servicios.` }, { type: "p", text: `Dicha propuesta no se entenderá aceptada por haber solicitado la auditoría, por haber mantenido conversaciones con MODIRA ni por haber recibido el análisis. Tampoco generará por sí misma ninguna obligación de pago.` }, { type: "p", text: `La contratación de cualquier servicio posterior requerirá su correspondiente aceptación mediante el procedimiento establecido por MODIRA.` }, { type: "p", text: `Los Términos distinguen expresamente la auditoría del posterior proceso de contratación mediante presupuesto.` }] },
  { id: `marketing`, number: `6`, title: `LA AUDITORÍA NO IMPLICA SUSCRIPCIÓN A MARKETING`, blocks: [{ type: "highlight", text: `Solicitar una auditoría gratuita no significa suscribirse a comunicaciones comerciales de MODIRA.` }, { type: "p", text: `La información de contacto proporcionada se utilizará para gestionar la solicitud y mantener las comunicaciones necesarias relacionadas con ella.` }, { type: "p", text: `Por ejemplo, podrá utilizarse el correo electrónico para:` }, { type: "list", items: [`confirmar o gestionar la solicitud;`, `pedir información necesaria para realizar el análisis;`, `comunicar cuestiones relacionadas con la auditoría;`, `enviar el resultado o las conclusiones del análisis;`, `aclarar cuestiones sobre la información proporcionada;`, `y, cuando corresponda, tratar una posible propuesta derivada de la propia solicitud.`] }, { type: "p", text: `Estas comunicaciones no convierten automáticamente la solicitud en una suscripción a publicidad o newsletters comerciales.` }, { type: "p", text: `La Política de Privacidad de MODIRA establece expresamente que la solicitud de una auditoría no implica automáticamente la inscripción en comunicaciones comerciales periódicas.` }] },
  { id: `despues`, number: `7`, title: `¿Y DESPUÉS DE LA AUDITORÍA?`, blocks: [{ type: "p", text: `Si después de conocer las conclusiones de la auditoría existe interés en continuar, MODIRA podrá resolver dudas, definir el alcance de un posible proyecto y, cuando corresponda, preparar un presupuesto.` }, { type: "p", text: `Si se decide no continuar, no será necesario contratar ningún servicio.` }, { type: "p", text: `La realización de la auditoría no crea una relación de mantenimiento, soporte o prestación continuada de servicios.` }, { type: "quote", text: `La decisión sobre si la relación continúa corresponde a la persona o empresa solicitante. MODIRA no utilizará la auditoría gratuita como mecanismo para generar una obligación comercial posterior.` }] },
  { id: `comunicaciones`, number: `8`, title: `COMUNICACIONES POSTERIORES`, blocks: [{ type: "p", text: `Las comunicaciones posteriores a la solicitud se distinguirán entre comunicaciones necesarias y comunicaciones comerciales.` }, { type: "sub", text: `Comunicaciones necesarias` }, { type: "p", text: `MODIRA podrá contactar cuando resulte necesario para gestionar la auditoría solicitada o una posible relación derivada de ella.` }, { type: "example", text: `«Necesitamos aclarar este proceso para terminar el análisis.»` }, { type: "example", text: `«Ya hemos terminado la auditoría y te enviamos las conclusiones.»` }, { type: "p", text: `Estas comunicaciones están directamente relacionadas con la solicitud realizada.` }, { type: "sub", text: `Comunicaciones comerciales` }, { type: "p", text: `La recepción de comunicaciones comerciales se regirá por la normativa aplicable y, cuando sea necesario, requerirá el consentimiento o base jurídica correspondiente.` }, { type: "highlight", text: `La aceptación de estas Condiciones de Auditoría no constituye por sí misma consentimiento para recibir publicidad.` }, { type: "p", text: `Esta separación es coherente con el Aviso Legal y la Política de Privacidad de MODIRA.` }] },
  { id: `informacion`, number: `9`, title: `INFORMACIÓN NECESARIA PARA REALIZAR LA AUDITORÍA`, blocks: [{ type: "p", text: `Para solicitar una auditoría, MODIRA podrá solicitar determinada información básica sobre la persona solicitante y la empresa.` }, { type: "p", text: `Actualmente, el formulario de auditoría contempla, entre otros datos:` }, { type: "list", items: [`nombre;`, `correo electrónico;`, `empresa;`, `número de empleados;`, `descripción del proceso o necesidad planteada.`] }, { type: "p", text: `La Política de Privacidad de MODIRA identifica estos datos dentro del tratamiento asociado a las solicitudes de auditoría.` }, { type: "p", text: `La información deberá ser suficientemente veraz para permitir que MODIRA pueda entender la situación planteada.` }] },
  { id: `no-enviar`, number: `10`, title: `INFORMACIÓN QUE NO DEBERÍAS ENVIAR`, blocks: [{ type: "p", text: `Para realizar una primera auditoría no es necesario enviar información personal innecesaria.` }, { type: "p", text: `Salvo que MODIRA indique expresamente lo contrario y exista una base adecuada para ello, se deberá evitar proporcionar:` }, { type: "list", items: [`contraseñas;`, `claves de acceso;`, `tokens;`, `credenciales de terceros;`, `datos bancarios;`, `números completos de tarjetas;`, `información especialmente sensible que no sea necesaria;`, `datos personales de clientes, trabajadores o terceros que no resulten necesarios para explicar el proceso.`] }, { type: "p", text: `La Política de Privacidad de MODIRA recomienda evitar introducir información personal innecesaria, especialmente datos personales de terceros o categorías especiales de datos.` }, { type: "highlight", text: `Para explicar cómo funciona un proceso normalmente no es necesario conocer todos los datos reales que contiene. En muchos casos basta con explicar qué ocurre, qué herramientas intervienen y qué resultado se busca.` }] },
  { id: `confidencialidad`, number: `11`, title: `CONFIDENCIALIDAD DE LA INFORMACIÓN PROPORCIONADA`, blocks: [{ type: "p", text: `MODIRA tratará la información recibida durante la auditoría de acuerdo con la normativa aplicable y con su Política de Privacidad.` }, { type: "p", text: `El acceso interno a información personal estará limitado a las personas autorizadas que necesiten acceder a ella para desarrollar sus funciones.` }, { type: "p", text: `Las personas autorizadas deberán mantener la confidencialidad de la información a la que tengan acceso.` }, { type: "p", text: `La persona solicitante deberá evitar proporcionar información que no sea necesaria para realizar el análisis.` }] },
  { id: `terceros`, number: `12`, title: `CUANDO EXISTAN DATOS PERSONALES DE TERCEROS`, blocks: [{ type: "p", text: `Si durante la auditoría una empresa proporciona información que contiene datos personales de sus clientes, trabajadores, proveedores u otras personas, deberá hacerlo únicamente cuando resulte necesario y de conformidad con la normativa aplicable.` }, { type: "p", text: `Cuando MODIRA trate datos personales por cuenta de una empresa cliente y siguiendo sus instrucciones, podrá resultar aplicable el régimen de encargado del tratamiento y, cuando corresponda, deberá formalizarse el correspondiente Acuerdo de Encargo del Tratamiento.` }, { type: "highlight", text: `Estas Condiciones de Auditoría no sustituyen dicho acuerdo cuando legalmente sea necesario.` }] },
  { id: `alcance`, number: `13`, title: `ALCANCE Y DURACIÓN DE LA AUDITORÍA`, blocks: [{ type: "p", text: `La auditoría no tiene un alcance idéntico para todas las empresas.` }, { type: "p", text: `MODIRA podrá determinar el alcance razonable del análisis teniendo en cuenta:` }, { type: "list", items: [`la información proporcionada;`, `la complejidad del proceso;`, `el tamaño o características de la empresa;`, `la disponibilidad de información;`, `la naturaleza de la necesidad planteada;`, `y el tiempo razonablemente necesario para realizar un análisis inicial.`] }, { type: "p", text: `La auditoría gratuita no constituye un servicio de consultoría ilimitado ni implica que MODIRA deba analizar todos los procesos de la empresa.` }, { type: "p", text: `Su finalidad es realizar una primera evaluación orientativa para determinar si existen oportunidades de mejora y, cuando proceda, si tiene sentido plantear un proyecto posterior.` }] },
  { id: `propuesta`, number: `14`, title: `POSIBLE PROPUESTA POSTERIOR`, blocks: [{ type: "p", text: `Cuando la auditoría permita identificar una solución que MODIRA considere viable, podrá plantearse una propuesta de servicios.` }, { type: "p", text: `Esta propuesta podrá incluir, entre otros elementos:` }, { type: "list", items: [`alcance;`, `funcionalidades;`, `entregables;`, `precio;`, `impuestos aplicables;`, `condiciones de pago;`, `plazo estimado;`, `mantenimiento;`, `garantía;`, `condiciones particulares.`] }, { type: "p", text: `La existencia de esta propuesta no implica que deba ser aceptada.` }, { type: "p", text: `La contratación se producirá únicamente cuando exista el correspondiente presupuesto, propuesta o documento contractual aplicable y sea aceptado conforme al procedimiento establecido por MODIRA.` }] },
  { id: `flujo`, number: `15`, title: `NO EXISTE CONTRATACIÓN AUTOMÁTICA`, blocks: [{ type: "p", text: `La relación entre la auditoría y una eventual contratación posterior sigue, de forma general, este proceso:` }, { type: "process", items: [`Solicitar una auditoría`, `MODIRA analiza el caso`, `Recibir las conclusiones`, `Decidir si se quiere continuar`, `Si existe interés → se estudia una propuesta`, `Se presenta un presupuesto`, `Se decide si se acepta`, `Solo entonces comienza el servicio contratado`] }, { type: "quote", text: `Auditoría gratuita ≠ contratación.` }, { type: "quote", text: `Auditoría gratuita ≠ compromiso de contratar.` }] },
  { id: `limitaciones`, number: `16`, title: `LIMITACIONES DEL ANÁLISIS`, blocks: [{ type: "p", text: `Las conclusiones de una auditoría se basan en la información disponible durante su realización.` }, { type: "p", text: `Por ello, MODIRA no garantiza que el análisis permita detectar absolutamente todas las oportunidades de mejora existentes en una empresa.` }, { type: "p", text: `Una auditoría puede identificar determinadas oportunidades sin que ello implique que no existan otras alternativas, procesos o soluciones que no hayan sido analizados.` }, { type: "p", text: `Las conclusiones pueden requerir una evaluación técnica adicional antes de determinar la viabilidad, coste o alcance de una implementación.` }] },
  { id: `especializado`, number: `17`, title: `NO SUSTITUYE ASESORAMIENTO ESPECIALIZADO`, blocks: [{ type: "p", text: `La auditoría de MODIRA tiene una finalidad tecnológica y operativa.` }, { type: "p", text: `Salvo que se indique expresamente lo contrario, no constituye:` }, { type: "list", items: [`asesoramiento jurídico;`, `asesoramiento fiscal;`, `asesoramiento laboral;`, `auditoría financiera;`, `certificación normativa;`, `certificación de seguridad;`, `ni otro servicio profesional especializado distinto del análisis tecnológico y de procesos objeto de la auditoría.`] }, { type: "p", text: `Cuando un proyecto pueda afectar a ámbitos que requieran conocimientos profesionales específicos, la empresa deberá contar, cuando corresponda, con los profesionales competentes.` }] },
  { id: `seguridad`, number: `18`, title: `SEGURIDAD DURANTE EL PROCESO`, blocks: [{ type: "p", text: `MODIRA aplica medidas técnicas y organizativas destinadas a proteger la información gestionada a través de sus sistemas.` }, { type: "p", text: `La arquitectura de MODIRA incorpora mecanismos de autenticación, control de acceso, aislamiento entre empresas, políticas de seguridad, protección frente al abuso y controles específicos para operaciones sensibles.` }, { type: "p", text: `No obstante, ningún sistema conectado a Internet puede garantizar una seguridad absoluta.` }, { type: "highlight", text: `La persona solicitante deberá evitar compartir credenciales o información que no sea necesaria para realizar la auditoría.` }] },
  { id: `abuso`, number: `19`, title: `PROTECCIÓN FRENTE AL USO ABUSIVO DEL FORMULARIO`, blocks: [{ type: "p", text: `El formulario público de auditoría incorpora medidas técnicas destinadas a evitar usos abusivos o automatizados.` }, { type: "p", text: `Actualmente, MODIRA limita las solicitudes de auditoría y utiliza un identificador técnico calculado en backend a partir de información de conexión, almacenado mediante hash.` }, { type: "p", text: `La arquitectura actual establece un límite de 3 solicitudes por identidad y hora y elimina el acceso de inserción directo desde el frontend, trasladando la operación a una función protegida.` }, { type: "p", text: `Estas medidas tienen una finalidad exclusivamente técnica y de seguridad.` }, { type: "highlight", text: `No constituyen una herramienta de marketing ni se utilizan para convertir la solicitud en una suscripción comercial.` }] },
  { id: `privacidad`, number: `20`, title: `PROTECCIÓN DE DATOS`, blocks: [{ type: "p", text: `El tratamiento de los datos personales asociados a la solicitud de auditoría se realizará conforme a la Política de Privacidad de MODIRA.` }, { type: "p", text: `En particular, los datos de la solicitud pueden tratarse para:` }, { type: "list", items: [`recibir y gestionar la solicitud;`, `analizar la necesidad planteada;`, `responder a la persona solicitante;`, `mantener las comunicaciones necesarias;`, `y preparar, cuando corresponda, una eventual relación contractual.`] }, { type: "p", text: `La Política de Privacidad identifica como base jurídica principal para este tratamiento la adopción de medidas precontractuales a petición del interesado.` }, { type: "highlight", text: `La solicitud de auditoría no implica automáticamente la inscripción en comunicaciones comerciales periódicas.` }, { type: "p", text: `Para obtener información completa sobre el tratamiento de datos, deben consultarse la Política de Privacidad y, cuando corresponda, las informaciones específicas proporcionadas durante el proceso.` }] },
  { id: `aceptacion`, number: `21`, title: `ACEPTACIÓN DE ESTAS CONDICIONES`, blocks: [{ type: "p", text: `Para solicitar una auditoría gratuita, la persona solicitante deberá manifestar que ha leído y acepta estas Condiciones de la Auditoría Gratuita cuando el mecanismo habilitado por MODIRA así lo requiera.` }, { type: "p", text: `La aceptación se referirá exclusivamente a las condiciones aplicables a la auditoría.` }, { type: "p", text: `No constituye:` }, { type: "list", items: [`aceptación de un presupuesto;`, `contratación de un servicio;`, `consentimiento general para recibir comunicaciones comerciales;`, `ni autorización para realizar tratamientos de datos distintos de los informados en la Política de Privacidad o en las informaciones correspondientes.`] }, { type: "p", text: `La aceptación electrónica podrá quedar registrada como evidencia de la acción realizada.` }, { type: "p", text: `La arquitectura legal de MODIRA distingue expresamente entre aceptar condiciones, ser informado sobre privacidad y consentir comunicaciones comerciales.` }] },
  { id: `decision`, number: `22`, title: `DECISIÓN DE CONTINUAR O NO CONTINUAR`, blocks: [{ type: "p", text: `La decisión de continuar trabajando con MODIRA corresponde exclusivamente a la persona o empresa solicitante.` }, { type: "p", text: `MODIRA podrá presentar una propuesta cuando considere que existe una oportunidad razonable de colaboración, pero la persona solicitante podrá:` }, { type: "list", items: [`aceptarla;`, `rechazarla;`, `solicitar modificaciones;`, `solicitar aclaraciones;`, `o simplemente decidir no continuar.`] }, { type: "quote", text: `No continuar no genera ninguna penalización ni coste por la auditoría realizada.` }] },
  { id: `ausencia`, number: `23`, title: `AUSENCIA DE COMPROMISO COMERCIAL`, blocks: [{ type: "p", text: `La relación entre MODIRA y la persona solicitante durante esta fase tiene carácter inicial y precontractual.` }, { type: "p", text: `La realización de la auditoría no supone que MODIRA se comprometa a:` }, { type: "list", items: [`desarrollar posteriormente el proyecto;`, `mantener una relación comercial;`, `reservar disponibilidad;`, `mantener un determinado precio;`, `implementar las soluciones identificadas;`, `ni aceptar cualquier proyecto posterior.`] }, { type: "p", text: `Del mismo modo, la persona solicitante no queda obligada a contratar.` }] },
  { id: `modificaciones`, number: `24`, title: `MODIFICACIONES DE ESTAS CONDICIONES`, blocks: [{ type: "p", text: `MODIRA podrá actualizar estas Condiciones cuando resulte necesario debido a:` }, { type: "list", items: [`cambios en el funcionamiento de la auditoría;`, `cambios en los servicios;`, `cambios tecnológicos;`, `modificaciones de la plataforma;`, `cambios legislativos;`, `o cualquier otra circunstancia que haga necesaria su actualización.`] }, { type: "p", text: `La versión vigente estará disponible en el sitio web de MODIRA.` }, { type: "p", text: `Las modificaciones no afectarán retroactivamente a situaciones o relaciones ya consolidadas cuando la legislación aplicable no permita dicha modificación.` }] },
  { id: `otros`, number: `25`, title: `RELACIÓN CON OTROS DOCUMENTOS LEGALES`, blocks: [{ type: "p", text: `Estas Condiciones forman parte del marco legal de MODIRA, pero no sustituyen a sus demás documentos.` }, { type: "doc", title: `Aviso Legal`, text: `Identifica al titular y regula las condiciones generales relativas al sitio web.` }, { type: "doc", title: `Política de Privacidad`, text: `Explica el tratamiento de los datos personales.` }, { type: "doc", title: `Política de Cookies`, text: `Regula las cookies y tecnologías similares.` }, { type: "doc", title: `Términos y Condiciones`, text: `Regulan el uso de MODIRA y, cuando corresponda, las relaciones contractuales derivadas de los servicios.` }, { type: "doc", title: `Condiciones de la Auditoría Gratuita`, text: `Regulan específicamente la solicitud y realización de la auditoría inicial gratuita.` }, { type: "doc", title: `Presupuesto / contrato`, text: `Regula las condiciones concretas de un servicio que posteriormente se contrate.` }, { type: "doc", title: `Acuerdo de Encargo del Tratamiento`, text: `Se formalizará cuando corresponda por razón del tratamiento de datos personales por cuenta de una empresa cliente.` }, { type: "p", text: `Esta separación es coherente con la estructura jurídica definida para MODIRA.` }] },
  { id: `legislacion`, number: `26`, title: `LEGISLACIÓN APLICABLE`, blocks: [{ type: "p", text: `Las presentes Condiciones se regirán por la legislación española, sin perjuicio de aquellas normas imperativas que pudieran resultar aplicables.` }] },
  { id: `contacto`, number: `27`, title: `CONTACTO`, blocks: [{ type: "p", text: `Para cualquier cuestión relacionada con estas Condiciones o con la realización de una auditoría gratuita puede contactarse con MODIRA mediante:` }, { type: "contact", title: `Correo electrónico`, text: `info@modira.es` }] },
];

export default function FreeAuditConditions() {
  const [isScrolled, setIsScrolled] = useState(false);
  const [openMobileToc, setOpenMobileToc] = useState(false);

  useEffect(() => {
    const onScroll = () => setIsScrolled(window.scrollY > 20);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const renderBlock = (block: Block, section: Section, index: number) => {
    switch (block.type) {
      case "p":
        return (
          <p key={index} className="text-[15px] md:text-base text-gray-600 leading-7">
            {block.text}
          </p>
        );

      case "list":
        return (
          <div key={index} className="my-1 rounded-xl border border-gray-100 bg-[#FBFCFE] overflow-hidden divide-y divide-gray-100">
            {block.items.map((item, itemIndex) => (
              <div key={itemIndex} className="flex items-start gap-3 px-4 md:px-5 py-3.5">
                <span className="mt-[9px] w-1.5 h-1.5 rounded-full bg-[#1E3A8A] flex-shrink-0" />
                <span className="text-[15px] md:text-base text-gray-600 leading-7">
                  {item}
                </span>
              </div>
            ))}
          </div>
        );

      case "highlight":
        return (
          <div key={index} className="rounded-xl border border-blue-100 bg-[#F3F7FF] px-5 py-4 md:px-6 md:py-5">
            <p className="font-semibold text-[#173B8F] text-[15px] md:text-base leading-7">
              {block.text}
            </p>
          </div>
        );

      case "quote":
        return (
          <div key={index} className="relative rounded-2xl border border-blue-100 bg-gradient-to-br from-[#F3F7FF] to-white px-5 py-5 md:px-7 md:py-6">
            <div className="absolute left-0 top-5 bottom-5 w-1 rounded-r-full bg-[#1E3A8A]" />
            <p className="pl-3 text-[15px] md:text-base font-semibold text-gray-700 leading-7">
              {block.text}
            </p>
          </div>
        );

      case "sub":
        return (
          <div key={index} className="pt-5 mt-2 border-t border-gray-100">
            <h3 className="text-base md:text-lg font-semibold text-[#1E3A8A]">
              {block.text}
            </h3>
          </div>
        );

      case "example":
        return (
          <div key={index} className="rounded-lg bg-gray-50 border-l-2 border-gray-200 px-4 py-3">
            <p className="text-sm md:text-[15px] text-gray-500 italic leading-6">
              {block.text}
            </p>
          </div>
        );

      case "process":
        return (
          <div key={index} className="rounded-2xl border border-blue-100 bg-[#F8FAFC] p-4 md:p-6">
            <div className="flex flex-col items-stretch">
              {block.items.map((item, stepIndex) => (
                <div key={stepIndex}>
                  <div className="flex items-center gap-3 md:gap-4 rounded-xl border border-gray-100 bg-white px-4 md:px-5 py-4 shadow-sm">
                    <span className="flex-shrink-0 w-8 h-8 rounded-full bg-[#EFF6FF] text-[#1E3A8A] flex items-center justify-center text-xs font-bold">
                      {String(stepIndex + 1).padStart(2, "0")}
                    </span>
                    <span className="text-[14px] md:text-[15px] font-medium text-gray-700 leading-6">
                      {item}
                    </span>
                  </div>

                  {stepIndex < block.items.length - 1 && (
                    <div className="flex justify-center h-8 items-center" aria-hidden="true">
                      <div className="h-8 w-px bg-blue-100 relative">
                        <ChevronDown size={14} className="absolute left-1/2 -translate-x-1/2 bottom-[-3px] text-[#1E3A8A] bg-[#F8FAFC]" />
                      </div>
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>
        );

      case "doc":
        return (
          <div key={index} className="rounded-xl border border-gray-100 bg-[#F8FAFC] px-5 py-4 md:px-6">
            <h3 className="text-sm md:text-base font-semibold text-[#1E3A8A] mb-1.5">
              {block.title}
            </h3>
            <p className="text-sm md:text-[15px] text-gray-600 leading-6">
              {block.text}
            </p>
          </div>
        );

      case "contact":
      case "meta":
        return (
          <div key={index} className="rounded-xl border border-gray-100 bg-[#F8FAFC] px-5 py-4">
            <div className="grid sm:grid-cols-[190px_1fr] gap-2 sm:gap-6">
              <span className="text-sm font-semibold text-gray-700">{block.title}</span>
              {block.type === "contact" ? (
                <a
                  href="mailto:info@modira.es"
                  className="text-sm text-[#1E3A8A] hover:underline break-words"
                >
                  {block.text}
                </a>
              ) : (
                <span className="text-sm text-gray-500 break-words">{block.text}</span>
              )}
            </div>
          </div>
        );
    }
  };

  return (
    <div className="min-h-screen bg-[#F8FAFC]">
      <div
        className={`audit-header-wrapper ${
          isScrolled ? "audit-header-scrolled" : "audit-header-transparent"
        }`}
      >
        <Header />
      </div>

      {/* Header / title */}
      <section className="pt-32 pb-14 md:pt-36 md:pb-16 bg-white border-b border-gray-100">
        <div className="container-lg mx-auto px-6 md:px-10 lg:px-12">
          <div className="max-w-5xl mx-auto">
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
                    Condiciones de la Auditoría Gratuita
                  </h1>
                  <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
                    Condiciones aplicables a la solicitud y realización de la auditoría inicial gratuita ofrecida por MODIRA.
                  </p>
                  <div className="mt-6 text-sm text-gray-400">
                    Última actualización: 13 de septiembre de 2026
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Intro / statement of intent */}
      <section className="relative overflow-hidden bg-[#102A66] text-white">
        <div className="absolute inset-0 pointer-events-none" aria-hidden="true">
          <div className="absolute -top-32 -right-24 w-80 h-80 rounded-full bg-blue-400/10 blur-3xl" />
          <div className="absolute -bottom-40 -left-20 w-96 h-96 rounded-full bg-blue-300/10 blur-3xl" />
          <div className="absolute inset-0 opacity-[0.07]" style={{
            backgroundImage: "radial-gradient(circle at 1px 1px, white 1px, transparent 0)",
            backgroundSize: "28px 28px"
          }} />
        </div>

        <div className="relative container-lg mx-auto px-6 md:px-10 lg:px-12 py-16 md:py-20">
          <div className="max-w-3xl mx-auto text-center">
            <div className="inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/10 px-4 py-2 text-[11px] font-semibold uppercase tracking-[0.16em] text-blue-100 mb-7">
              <CheckCircle2 size={15} />
              Antes de empezar
            </div>

            <h2 className="text-3xl md:text-4xl font-bold tracking-tight mb-5">
              Una auditoría gratuita. De verdad.
            </h2>

            <p className="text-base md:text-lg text-blue-100 leading-7 max-w-2xl mx-auto mb-8">
              La finalidad de esta auditoría es sencilla: analizar el caso planteado,
              identificar posibles oportunidades de mejora y explicar qué puede tener
              sentido hacer a continuación.
            </p>

            <div className="grid sm:grid-cols-3 gap-3 max-w-2xl mx-auto mb-8">
              <div className="rounded-xl border border-white/10 bg-white/[0.07] px-4 py-4">
                <p className="text-sm font-semibold text-white">Sin coste</p>
                <p className="text-xs text-blue-100/80 mt-1">La auditoría es gratuita.</p>
              </div>
              <div className="rounded-xl border border-white/10 bg-white/[0.07] px-4 py-4">
                <p className="text-sm font-semibold text-white">Sin contratación</p>
                <p className="text-xs text-blue-100/80 mt-1">No obliga a contratar.</p>
              </div>
              <div className="rounded-xl border border-white/10 bg-white/[0.07] px-4 py-4">
                <p className="text-sm font-semibold text-white">Sin marketing automático</p>
                <p className="text-xs text-blue-100/80 mt-1">La solicitud no suscribe publicidad.</p>
              </div>
            </div>

            <p className="text-sm md:text-[15px] text-white/80 leading-7 max-w-2xl mx-auto">
              Si posteriormente existe interés en trabajar con MODIRA, podrá estudiarse
              una propuesta independiente. Si no existe interés, la auditoría termina ahí.
            </p>
          </div>
        </div>
      </section>

      <main className="container-lg mx-auto px-6 md:px-10 lg:px-12 py-14 md:py-20">
        <div className="max-w-6xl mx-auto">
          {/* Mobile contents */}
          <div className="lg:hidden mb-8 rounded-2xl border border-gray-100 bg-white shadow-sm overflow-hidden">
            <button
              type="button"
              onClick={() => setOpenMobileToc((v) => !v)}
              className="w-full flex items-center justify-between px-5 py-4 text-sm font-semibold text-[#1E3A8A]"
              aria-expanded={openMobileToc}
            >
              <span>Contenido del documento</span>
              <ChevronDown className={`transition-transform ${openMobileToc ? "rotate-180" : ""}`} size={18} />
            </button>

            {openMobileToc && (
              <nav className="border-t border-gray-100 px-5 py-4 space-y-1">
                {sections.map((section) => (
                  <a
                    key={section.id}
                    href={`#${section.id}`}
                    onClick={() => setOpenMobileToc(false)}
                    className="flex gap-3 py-2 text-xs text-gray-500 hover:text-[#1E3A8A]"
                  >
                    <span className="w-5 flex-shrink-0 text-gray-400">{section.number}.</span>
                    <span>{section.title}</span>
                  </a>
                ))}
              </nav>
            )}
          </div>

          <div className="grid lg:grid-cols-[245px_minmax(0,1fr)] gap-10 lg:gap-16">
            {/* Desktop contents */}
            <aside className="hidden lg:block">
              <div className="sticky top-28">
                <p className="text-xs font-semibold uppercase tracking-[0.14em] text-gray-400 mb-4">
                  Contenido
                </p>
                <nav className="space-y-0.5 max-h-[calc(100vh-160px)] overflow-y-auto pr-3">
                  {sections.map((section) => (
                    <a
                      key={section.id}
                      href={`#${section.id}`}
                      className="group flex items-start gap-2.5 py-1.5 text-[11px] text-gray-500 hover:text-[#1E3A8A] transition-colors"
                    >
                      <span className="w-5 flex-shrink-0 text-gray-400 group-hover:text-[#1E3A8A]">
                        {section.number}.
                      </span>
                      <span className="leading-[1.45]">{section.title}</span>
                    </a>
                  ))}
                </nav>
              </div>
            </aside>

            <div className="min-w-0">
              <article className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="px-6 py-8 md:px-10 md:py-12 lg:px-14">
                  {/* Document metadata */}
                  <div className="pb-10 mb-10 border-b border-gray-100">
                    <p className="text-sm font-semibold text-[#1E3A8A] mb-2">
                      CONDICIONES DE LA AUDITORÍA GRATUITA DE MODIRA
                    </p>
                    <div className="grid sm:grid-cols-3 gap-3 text-sm leading-7 text-gray-500">
                      <p><span className="font-medium text-gray-700">Versión:</span> 1.0</p>
                      <p><span className="font-medium text-gray-700">Elaboración:</span> 13 de septiembre de 2026</p>
                      <p><span className="font-medium text-gray-700">Entrada en vigor:</span> 13 de septiembre de 2026</p>
                    </div>
                  </div>

                  <div className="space-y-14">
                    {sections.map((section) => (
                      <section key={section.id} id={section.id} className="scroll-mt-28">
                        <div className="flex items-start gap-4 mb-6">
                          <div className="flex-shrink-0 w-9 h-9 rounded-lg bg-[#EFF6FF] flex items-center justify-center">
                            <span className="text-xs font-bold text-[#1E3A8A]">{section.number}</span>
                          </div>
                          <h2 className="text-xl md:text-2xl font-bold text-[#1E3A8A] leading-tight pt-1">
                            {section.title}
                          </h2>
                        </div>

                        <div className="pl-0 md:pl-[52px] space-y-5">
                          {section.blocks.map((block, index) =>
                            renderBlock(block, section, index)
                          )}
                        </div>
                      </section>
                    ))}
                  </div>

                  <div className="mt-16 pt-8 border-t border-gray-100">
                    <p className="text-sm text-gray-400 leading-6">
                      Versión 1.0 · Elaborado el 13 de septiembre de 2026 · Entrada en vigor el 13 de septiembre de 2026.
                    </p>
                  </div>
                </div>
              </article>
            </div>
          </div>
        </div>
      </main>

      <style>{`
        .audit-header-wrapper {
          position: relative;
          z-index: 50;
          min-height: 0;
          transition: background-color 250ms ease, box-shadow 250ms ease;
        }

        .audit-header-transparent {
          background: linear-gradient(to right, #102A66, #173B8F) !important;
          box-shadow: 0 4px 12px rgba(16, 42, 102, 0.18) !important;
        }

        .audit-header-transparent header {
          background: linear-gradient(to right, #102A66, #173B8F) !important;
          box-shadow: none !important;
        }

        .audit-header-scrolled {
          background-color: #ffffff !important;
          box-shadow: 0 1px 0 rgba(15, 23, 42, 0.06) !important;
        }

        .audit-header-scrolled header {
          background-color: #ffffff !important;
          box-shadow: none !important;
        }
      `}</style>
    </div>
  );
}
