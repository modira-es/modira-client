import { useEffect, useState } from "react";
import Header from "@/components/Header";
import {
  ArrowLeft,
  FileText,
  ChevronRight,
} from "lucide-react";

export default function TermsAndConditions() {
  const [isScrolled, setIsScrolled] = useState(false);

  /*
   * ============================================================
   * MODIRA — TERMS AND CONDITIONS
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

  const sections = [
   

    {
      id: "objeto",
      number: "1",
      title: "Objeto y ámbito de aplicación",
      paragraphs: [
        "Los presentes Términos y Condiciones regulan:",
      ],
      bullets: [
        "el acceso y utilización de la plataforma MODIRA;",
        "la utilización del Área de Cliente;",
        "la solicitud de auditorías;",
        "la creación y gestión de proyectos;",
        "la elaboración y aceptación de presupuestos;",
        "la contratación de servicios de automatización;",
        "la prestación de servicios de implementación, integración, documentación, soporte y mantenimiento;",
        "la utilización de funcionalidades de MODIRA AI;",
        "la gestión de pagos y facturación;",
        "las condiciones aplicables a la cancelación, modificaciones y garantía.",
      ],
      afterBullets: [
        "MODIRA está orientada actualmente a empresas, autónomos y profesionales que actúen en el marco de su actividad económica o profesional.",
        "Los presentes Términos no están concebidos como condiciones de contratación dirigidas a consumidores que actúen con un propósito ajeno a su actividad profesional.",
        "Cuando una relación contractual concreta requiera condiciones particulares, estas podrán establecerse en el correspondiente presupuesto, propuesta, contrato o documento asociado al proyecto. Dichas condiciones particulares complementarán los presentes Términos.",
      ],
    },

    {
      id: "aceptacion",
      number: "2",
      title: "Aceptación de los Términos",
      paragraphs: [
        "El acceso y utilización de determinadas funcionalidades de MODIRA puede requerir la aceptación de los presentes Términos.",
        "Cuando se cree una cuenta o se utilice una funcionalidad que requiera aceptación contractual, el usuario deberá manifestar su aceptación mediante el mecanismo habilitado por MODIRA.",
        "La aceptación electrónica realizada mediante los mecanismos habilitados por MODIRA será registrada como evidencia de la aceptación correspondiente.",
        "La utilización de la plataforma después de la aceptación implicará el conocimiento y aceptación de los presentes Términos en aquello que resulte aplicable.",
        "La aceptación de estos Términos no sustituye los consentimientos específicos que puedan resultar necesarios para otros tratamientos, como determinados tratamientos basados en consentimiento o el uso de cookies no necesarias.",
      ],
    },

    {
      id: "requisitos",
      number: "3",
      title: "Requisitos para utilizar MODIRA",
      paragraphs: [
        "Para utilizar las funcionalidades destinadas a clientes será necesario proporcionar información veraz, actualizada y suficiente.",
        "El usuario deberá:",
      ],
      bullets: [
        "proporcionar información correcta;",
        "mantener actualizados sus datos;",
        "mantener la confidencialidad de sus credenciales;",
        "utilizar su cuenta de forma responsable;",
        "no facilitar sus credenciales a terceros;",
        "comunicar a MODIRA cualquier acceso no autorizado que detecte;",
        "utilizar la plataforma de conformidad con la legislación aplicable.",
      ],
      afterBullets: [
        "Cuando una persona actúe en nombre de una empresa u organización, declara disponer de las facultades necesarias para utilizar MODIRA y, cuando corresponda, aceptar obligaciones contractuales en nombre de dicha entidad.",
      ],
    },

    {
      id: "servicios",
      number: "4",
      title: "Servicios de MODIRA",
      paragraphs: [
        "MODIRA presta servicios relacionados con la automatización y mejora de procesos empresariales.",
        "Entre ellos pueden encontrarse:",
      ],
      bullets: [
        "análisis de procesos;",
        "auditorías;",
        "identificación de oportunidades de automatización;",
        "diseño de automatizaciones;",
        "desarrollo e implementación;",
        "integración de herramientas y servicios;",
        "documentación;",
        "soporte;",
        "mantenimiento;",
        "mejoras y modificaciones de soluciones existentes.",
      ],
      afterBullets: [
        "Los servicios concretos que se presten a cada cliente dependerán del proyecto y del presupuesto aceptado.",
        "La información publicada en la web sobre servicios y precios tiene carácter orientativo, salvo que expresamente se indique lo contrario.",
        "Los precios base mostrados en la web no constituyen por sí mismos una oferta contractual ni determinan el precio final de un proyecto.",
        "El precio final, alcance, condiciones y características del servicio se establecerán en el presupuesto correspondiente.",
      ],
    },

    {
      id: "auditoria",
      number: "5",
      title: "Auditoría inicial gratuita",
      paragraphs: [
        "MODIRA puede ofrecer una auditoría o análisis inicial gratuito para identificar necesidades, procesos susceptibles de mejora y posibles oportunidades de automatización.",
        "La auditoría:",
      ],
      bullets: [
        "es gratuita;",
        "puede variar en alcance y profundidad;",
        "depende de la información proporcionada por el cliente;",
        "depende de las características y complejidad de la empresa;",
        "no garantiza un número determinado de automatizaciones;",
        "no garantiza un ahorro económico o de tiempo determinado;",
        "no garantiza que todos los procesos puedan automatizarse;",
        "no garantiza que posteriormente se realice una propuesta económica;",
        "no obliga a MODIRA ni al cliente a contratar posteriormente un proyecto.",
      ],
      afterBullets: [
        "La auditoría tiene como finalidad facilitar un análisis inicial y, cuando proceda, servir de base para una posible propuesta de servicios.",
      ],
    },

    {
      id: "inicio-proyectos",
      number: "6",
      title: "Inicio de proyectos",
      paragraphs: [
        "Un proyecto puede iniciarse como consecuencia de una auditoría o directamente a iniciativa del cliente desde el Área de Cliente.",
        "Cuando un cliente inicie directamente un proyecto, podrá proporcionar una descripción de sus necesidades, objetivos o procesos.",
        "MODIRA podrá analizar la información proporcionada y solicitar información adicional cuando resulte necesaria para determinar el alcance y viabilidad del proyecto.",
        "El inicio de un proyecto dentro del Área de Cliente no implica por sí mismo la contratación ni genera automáticamente una obligación de pago.",
        "La contratación se producirá cuando exista un presupuesto o documento contractual aplicable y este haya sido aceptado conforme al procedimiento establecido.",
      ],
    },

    {
      id: "presupuestos",
      number: "7",
      title: "Presupuestos",
      paragraphs: [
        "Cuando MODIRA determine que procede realizar un proyecto, podrá emitir un presupuesto.",
        "El presupuesto podrá especificar, entre otros elementos:",
      ],
      bullets: [
        "descripción del servicio;",
        "alcance;",
        "entregables;",
        "precio;",
        "impuestos aplicables;",
        "condiciones de pago;",
        "plazo o estimación de ejecución cuando proceda;",
        "condiciones particulares;",
        "garantía;",
        "mantenimiento, cuando corresponda;",
        "otras condiciones relevantes del proyecto.",
      ],
      afterBullets: [
        "Salvo que el propio presupuesto establezca un período diferente, los presupuestos de MODIRA tendrán una validez de 15 días desde su emisión.",
        "Transcurrido dicho período, MODIRA podrá revisar las condiciones, precio, disponibilidad o alcance antes de aceptar una contratación.",
      ],
    },

    {
      id: "aceptacion-presupuesto",
      number: "8",
      title: "Aceptación del presupuesto",
      paragraphs: [
        "La aceptación del presupuesto se realizará electrónicamente desde el Área de Cliente o mediante el mecanismo que MODIRA habilite para cada contratación.",
        "Antes de aceptar un presupuesto, el cliente podrá consultar sus condiciones esenciales, incluyendo el alcance, precio, impuestos, condiciones de ejecución, cancelación y garantía cuando sean aplicables.",
        "La aceptación registrada por MODIRA constituirá evidencia de la voluntad del cliente de contratar el proyecto en las condiciones especificadas.",
        "Una vez aceptado el presupuesto, MODIRA podrá comenzar los trabajos conforme al alcance contratado.",
        "La contratación electrónica no requiere la firma manuscrita del documento cuando el mecanismo utilizado permita acreditar adecuadamente el consentimiento.",
      ],
    },

    {
      id: "formalizacion",
      number: "9",
      title: "Formalización y archivo del contrato",
      paragraphs: [
        "MODIRA podrá conservar electrónicamente los presupuestos aceptados, las condiciones particulares y la información asociada a la contratación.",
        "El cliente podrá consultar la información de sus presupuestos y contratación desde el Área de Cliente cuando dicha funcionalidad esté disponible.",
        "MODIRA podrá proporcionar al cliente copia o información sobre la contratación cuando resulte necesario.",
        "El procedimiento de contratación se realizará en español, sin perjuicio de que MODIRA pueda ofrecer otros idiomas en el futuro.",
      ],
    },

    {
      id: "errores",
      number: "10",
      title: "Corrección de errores",
      paragraphs: [
        "Antes de aceptar un presupuesto o completar una contratación, el cliente deberá comprobar que los datos y condiciones mostrados son correctos.",
        "Cuando el sistema de contratación permita modificar los datos introducidos, el cliente podrá corregirlos antes de confirmar la aceptación.",
        "Si el cliente detecta posteriormente un error en la información de contratación, deberá comunicarlo a MODIRA a través de los canales disponibles.",
        "MODIRA podrá corregir errores materiales cuando proceda y siempre que ello no suponga alterar unilateralmente las condiciones esenciales de una contratación ya aceptada.",
      ],
    },

    {
      id: "ejecucion",
      number: "11",
      title: "Ejecución de los proyectos",
      paragraphs: [
        "Una vez aceptado el presupuesto, MODIRA realizará los trabajos incluidos en el alcance contratado.",
        "El proyecto podrá incluir fases de:",
      ],
      numbered: [
        "análisis;",
        "definición;",
        "desarrollo o configuración;",
        "integración;",
        "pruebas;",
        "validación;",
        "demostración o entrega;",
        "documentación cuando corresponda.",
      ],
      afterNumbered: [
        "El alcance concreto dependerá del presupuesto aceptado.",
        "MODIRA y el cliente colaborarán proporcionando la información, accesos, documentación y demás elementos necesarios para ejecutar el proyecto.",
        "Cuando la ejecución dependa de terceros, herramientas externas, APIs, servicios de terceros o información que deba proporcionar el cliente, los plazos y resultados podrán verse afectados por circunstancias ajenas al control razonable de MODIRA.",
      ],
    },

    {
      id: "obligaciones-cliente",
      number: "12",
      title: "Obligaciones del cliente durante un proyecto",
      paragraphs: [
        "El cliente deberá facilitar de forma diligente la información necesaria para la correcta ejecución del proyecto.",
        "Cuando corresponda, deberá proporcionar:",
      ],
      bullets: [
        "información sobre sus procesos;",
        "documentación;",
        "accesos;",
        "requisitos técnicos;",
        "información sobre las herramientas que deban integrarse;",
        "instrucciones necesarias;",
        "información necesaria para realizar pruebas y validaciones.",
      ],
      afterBullets: [
        "El cliente será responsable de disponer de las autorizaciones necesarias para proporcionar a MODIRA información, documentos, accesos o datos de terceros.",
        "Cuando el proyecto implique datos personales tratados por cuenta del cliente, las partes deberán formalizar, cuando corresponda, el correspondiente Acuerdo de Encargo del Tratamiento (DPA).",
      ],
    },

    {
      id: "modificaciones-proyecto",
      number: "13",
      title: "Modificaciones del proyecto",
      paragraphs: [
        "Las modificaciones solicitadas por el cliente después de la aceptación del presupuesto estarán sujetas a evaluación.",
        "Una modificación podrá afectar:",
      ],
      bullets: [
        "al alcance;",
        "al precio;",
        "a los plazos;",
        "a las necesidades técnicas;",
        "a las integraciones;",
        "a los entregables.",
      ],
      afterBullets: [
        "MODIRA comunicará al cliente las condiciones aplicables cuando una modificación implique un cambio relevante respecto del proyecto originalmente contratado.",
        "No se considerará incluido en el precio original aquello que exceda del alcance expresamente aceptado.",
      ],
    },

    {
      id: "cancelacion",
      number: "14",
      title: "Cancelación del proyecto",
      subheadings: [
        {
          title: "Antes del inicio de los trabajos",
          paragraphs: [
            "Si el proyecto todavía no ha comenzado, la cancelación no generará, con carácter general, un importe correspondiente a trabajos de ejecución todavía no realizados.",
          ],
        },
        {
          title: "Después del inicio",
          paragraphs: [
            "Si el cliente solicita cancelar un proyecto una vez iniciados los trabajos, MODIRA podrá facturar el trabajo efectivamente realizado y justificable hasta el momento de la cancelación, conforme al alcance y condiciones del proyecto.",
            "Cuando existan costes de terceros previamente asumidos específicamente para el proyecto y que no puedan ser recuperados, podrán ser tenidos en cuenta cuando así se haya establecido en el presupuesto o condiciones particulares aplicables.",
            "La cancelación no afecta a las obligaciones que por su naturaleza deban continuar después de la finalización del proyecto.",
          ],
        },
      ],
    },

    {
      id: "entrega",
      number: "15",
      title: "Entrega, validación y aceptación",
      paragraphs: [
        "Cuando un proyecto incluya entregables o una solución implementada, MODIRA podrá realizar una demostración, puesta a disposición o fase de validación.",
        "El cliente deberá revisar el resultado y comunicar cualquier incidencia relacionada con el alcance contratado.",
        "La validación no implica que MODIRA garantice resultados empresariales concretos, ahorros determinados o una mejora económica específica.",
      ],
    },

    {
      id: "garantia",
      number: "16",
      title: "Garantía de los trabajos",
      paragraphs: [
        "Los proyectos realizados por MODIRA dispondrán de una garantía de 90 días, salvo que el presupuesto o las condiciones particulares establezcan expresamente otra condición más favorable.",
        "La garantía está destinada a atender incidencias atribuibles a la implementación realizada por MODIRA dentro del alcance contratado.",
        "La garantía no constituye una garantía de resultados económicos, de ahorro, de productividad o de funcionamiento permanente de servicios de terceros.",
        "Las modificaciones realizadas por el cliente o por terceros, cambios en servicios externos, cambios de APIs, credenciales, configuraciones, herramientas integradas o circunstancias ajenas al trabajo realizado por MODIRA podrán requerir una actuación adicional que quede fuera de la garantía.",
      ],
    },

    {
      id: "mantenimiento",
      number: "17",
      title: "Mantenimiento",
      paragraphs: [
        "El mantenimiento es un servicio opcional y distinto de la ejecución inicial del proyecto, salvo que el presupuesto indique expresamente que está incluido.",
        "MODIRA dispone de diferentes planes de mantenimiento que pueden contratarse según las necesidades del cliente.",
        "Las condiciones concretas de cada plan podrán incluir:",
      ],
      bullets: [
        "nombre del plan;",
        "servicios incluidos;",
        "precio;",
        "periodicidad;",
        "fecha de inicio;",
        "duración;",
        "condiciones de finalización.",
      ],
      afterBullets: [
        "Los contratos de mantenimiento podrán establecerse con periodicidad mensual, trimestral, semestral o anual, según el plan o condiciones contratadas.",
        "El mantenimiento contratado será gestionado conforme a las condiciones específicas del plan aceptado.",
      ],
    },

    {
      id: "soporte",
      number: "18",
      title: "Soporte",
      paragraphs: [
        "MODIRA puede proporcionar soporte mediante el sistema de tickets disponible en el Área de Cliente.",
        "El soporte podrá utilizarse para:",
      ],
      bullets: [
        "comunicar incidencias;",
        "solicitar asistencia;",
        "realizar consultas relacionadas con servicios contratados;",
        "comunicar problemas de funcionamiento;",
        "realizar seguimiento de incidencias.",
      ],
      afterBullets: [
        "El alcance del soporte dependerá del servicio contratado y, cuando exista, del plan de mantenimiento correspondiente.",
        "No se garantiza un tiempo de respuesta o resolución concreto salvo que haya sido expresamente contratado o indicado en las condiciones particulares.",
      ],
    },

    {
      id: "automatizaciones",
      number: "19",
      title: "Automatizaciones e integraciones",
      paragraphs: [
        "Las automatizaciones desarrolladas por MODIRA pueden depender de:",
      ],
      bullets: [
        "herramientas de terceros;",
        "APIs;",
        "servicios externos;",
        "sistemas del cliente;",
        "credenciales;",
        "permisos;",
        "configuraciones;",
        "disponibilidad de proveedores externos.",
      ],
      afterBullets: [
        "MODIRA no garantiza que una determinada herramienta o integración pueda mantenerse disponible indefinidamente.",
        "Los cambios realizados por terceros en sus APIs, servicios, condiciones técnicas o políticas pueden requerir modificaciones en las soluciones implementadas.",
        "Cuando una modificación sea necesaria como consecuencia de un cambio externo y quede fuera del alcance contratado, podrá considerarse un nuevo trabajo sujeto a presupuesto.",
      ],
    },

    {
      id: "resultados",
      number: "20",
      title: "Ausencia de garantía de resultados empresariales",
      paragraphs: [
        "MODIRA presta servicios orientados a mejorar y automatizar procesos, pero no garantiza resultados empresariales concretos.",
        "En particular, MODIRA no garantiza:",
      ],
      bullets: [
        "un ahorro económico determinado;",
        "un número concreto de horas ahorradas;",
        "un incremento determinado de ingresos;",
        "una reducción concreta de costes;",
        "que un proceso concreto pueda automatizarse;",
        "que una automatización sea completamente infalible;",
        "que una integración concreta permanezca disponible indefinidamente;",
        "un resultado comercial determinado;",
        "una mejora empresarial determinada.",
      ],
      afterBullets: [
        "Los resultados dependen, entre otros factores, de las características de cada empresa, procesos, herramientas, datos, decisiones del cliente y funcionamiento de servicios externos.",
      ],
    },

    {
      id: "modira-ai",
      number: "21",
      title: "MODIRA AI",
      paragraphs: [
        "MODIRA puede ofrecer funcionalidades de inteligencia artificial con finalidad principalmente informativa y asistencial.",
        "MODIRA AI puede proporcionar información sobre:",
      ],
      bullets: [
        "los servicios de MODIRA;",
        "funcionalidades de la plataforma;",
        "ideas de automatización;",
        "recomendaciones generales para negocios;",
        "posibles usos de MODIRA;",
        "información sobre la web y sus servicios;",
        "otras cuestiones planteadas por el usuario.",
      ],
      afterBullets: [
        "Las respuestas generadas por inteligencia artificial tienen carácter orientativo y no constituyen asesoramiento profesional especializado salvo que expresamente se indique lo contrario.",
        "El usuario deberá valorar y verificar la información proporcionada por la IA antes de utilizarla para adoptar decisiones relevantes.",
        "MODIRA no garantiza que una respuesta generada por IA sea siempre completa, exacta o adecuada para una situación concreta.",
        "La información relativa al tratamiento de las conversaciones, proveedores de IA y datos personales se encuentra en la Política de Privacidad.",
      ],
    },

    {
      id: "uso-ai",
      number: "22",
      title: "Uso permitido de MODIRA AI",
      paragraphs: [
        "El usuario no deberá utilizar MODIRA AI para:",
      ],
      bullets: [
        "realizar actividades ilícitas;",
        "intentar obtener acceso no autorizado a sistemas;",
        "introducir código malicioso;",
        "intentar eludir mecanismos de seguridad;",
        "abusar deliberadamente del servicio;",
        "utilizar la funcionalidad para generar contenido cuya utilización sea contraria a la legislación aplicable.",
      ],
      afterBullets: [
        "MODIRA podrá aplicar medidas técnicas de protección, limitación de uso o bloqueo cuando resulte necesario para proteger el servicio, a los usuarios o a terceros.",
      ],
    },

    {
      id: "disponibilidad",
      number: "23",
      title: "Disponibilidad del servicio",
      paragraphs: [
        "MODIRA procurará mantener disponible la plataforma y sus funcionalidades, pero no garantiza una disponibilidad absoluta o ininterrumpida.",
        "La disponibilidad puede verse afectada por:",
      ],
      bullets: [
        "mantenimiento;",
        "actualizaciones;",
        "incidencias técnicas;",
        "fallos de infraestructura;",
        "servicios de terceros;",
        "problemas de conectividad;",
        "acontecimientos fuera del control razonable de MODIRA;",
        "incidentes de seguridad;",
        "cambios en proveedores o tecnologías.",
      ],
      afterBullets: [
        "MODIRA adoptará medidas razonables para restaurar el servicio cuando se produzcan incidencias.",
      ],
    },

    {
      id: "cuentas",
      number: "24",
      title: "Cuentas y suspensión",
      paragraphs: [
        "MODIRA podrá suspender o bloquear una cuenta cuando resulte necesario por razones de:",
      ],
      bullets: [
        "seguridad;",
        "fraude;",
        "abuso;",
        "incumplimiento de estos Términos;",
        "utilización ilícita del servicio;",
        "riesgo para otros usuarios;",
        "riesgo para la infraestructura;",
        "incumplimiento de obligaciones de pago.",
      ],
      afterBullets: [
        "Cuando resulte razonablemente posible y compatible con la seguridad, MODIRA podrá informar al usuario de la causa de la suspensión.",
        "Las cuentas bloqueadas no podrán utilizar las funcionalidades protegidas de la plataforma.",
      ],
    },

    {
      id: "seguridad",
      number: "25",
      title: "Seguridad",
      paragraphs: [
        "MODIRA aplica medidas técnicas y organizativas destinadas a proteger la plataforma y la información gestionada a través de ella.",
        "Entre otras medidas, la arquitectura utiliza mecanismos de autenticación, control de acceso, aislamiento entre empresas, políticas de seguridad de base de datos, protección frente al abuso, limitación de solicitudes y controles específicos para operaciones sensibles.",
        "El usuario también es responsable de mantener seguras sus credenciales y de utilizar el servicio de forma diligente.",
      ],
    },

    {
      id: "propiedad",
      number: "26",
      title: "Propiedad intelectual de MODIRA",
      paragraphs: [
        "Los elementos propios de MODIRA, incluyendo, entre otros:",
      ],
      bullets: [
        "software;",
        "código;",
        "diseño;",
        "interfaz;",
        "estructura;",
        "logotipos;",
        "marca MODIRA;",
        "textos;",
        "gráficos;",
        "elementos visuales;",
        "contenidos propios;",
        "documentación propia;",
      ],
      afterBullets: [
        "son titularidad de MODIRA o se utilizan con las correspondientes autorizaciones.",
        "Salvo autorización expresa o cuando la ley disponga lo contrario, el usuario no podrá:",
      ],
      bullets2: [
        "copiar;",
        "reproducir;",
        "distribuir;",
        "modificar;",
        "descompilar;",
        "realizar ingeniería inversa;",
        "comercializar;",
        "explotar;",
        "redistribuir",
      ],
      afterBullets2: [
        "los elementos protegidos de MODIRA.",
        "La contratación de un servicio de desarrollo o automatización no implica por sí misma la transmisión de los derechos de propiedad intelectual sobre la plataforma MODIRA, su código fuente, herramientas internas o componentes preexistentes.",
        "Las condiciones específicas sobre los derechos de los entregables desarrollados para un cliente podrán establecerse en el presupuesto o contrato correspondiente.",
      ],
    },

    {
      id: "materiales",
      number: "27",
      title: "Contenido y materiales proporcionados por el cliente",
      paragraphs: [
        "El cliente conserva sus derechos sobre la información, documentación, materiales, procedimientos, marcas y demás contenidos que proporcione a MODIRA.",
        "El cliente declara disponer de los derechos y autorizaciones necesarios para proporcionar dichos materiales y permitir su utilización para la ejecución del proyecto.",
        "El cliente autoriza a MODIRA a utilizar los materiales proporcionados en la medida necesaria para prestar los servicios contratados.",
        "Cuando el tratamiento de datos personales se realice por cuenta del cliente, se aplicarán además las condiciones correspondientes del Acuerdo de Encargo del Tratamiento.",
      ],
    },

    {
      id: "terceros",
      number: "28",
      title: "Servicios y contenidos de terceros",
      paragraphs: [
        "MODIRA puede integrarse con servicios, herramientas, APIs o plataformas de terceros.",
        "Dichos servicios pueden estar sujetos a sus propias:",
      ],
      bullets: [
        "condiciones de uso;",
        "políticas de privacidad;",
        "limitaciones técnicas;",
        "precios;",
        "disponibilidad;",
        "modificaciones.",
      ],
      afterBullets: [
        "MODIRA no controla los servicios de terceros y no puede garantizar su disponibilidad, continuidad o funcionamiento.",
        "Cuando una integración dependa de un servicio externo, cualquier modificación realizada por dicho proveedor podrá afectar a la funcionalidad contratada.",
      ],
    },

    {
      id: "pagos",
      number: "29",
      title: "Pagos",
      paragraphs: [
        "El precio y las condiciones económicas de cada proyecto serán los establecidos en el presupuesto correspondiente y, cuando proceda, en las condiciones particulares del proyecto.",
        "La forma de pago podrá variar en función de las características del proyecto y podrá incluir pagos anticipados, pagos vinculados a fases o hitos de ejecución y pagos a la finalización o entrega.",
        "La estructura concreta de pagos aplicable a cada proyecto será comunicada al cliente antes de la aceptación del presupuesto y quedará reflejada en el mismo.",
        "Una vez aceptado el presupuesto, la distribución de pagos, los importes correspondientes y los hitos asociados quedarán fijados para el proyecto, salvo que las partes acuerden posteriormente una modificación.",
        "Los pagos se realizarán mediante los medios habilitados por MODIRA y dentro de los plazos indicados en las correspondientes facturas o condiciones particulares.",
        "Cuando resulte aplicable la normativa sobre morosidad en operaciones comerciales, los plazos de pago se establecerán dentro de los límites legalmente permitidos.",
      ],
    },

    {
      id: "hitos",
      number: "30",
      title: "Condiciones de pago y distribución por hitos",
      paragraphs: [
        "El importe y la estructura de pago de cada proyecto serán determinados por MODIRA atendiendo conjuntamente a las características particulares del proyecto y, en particular, a:",
      ],
      bullets: [
        "su complejidad;",
        "su duración prevista;",
        "el nivel de riesgo o exposición de recursos que implique para MODIRA.",
      ],
      afterBullets: [
        "Estos factores se valorarán conjuntamente. La estructura de pagos no se determinará exclusivamente por la complejidad técnica del proyecto.",
        "En función de estas características, MODIRA podrá establecer diferentes estructuras de pago, entre otras, las siguientes:",
      ],
      paymentPlans: [
        {
          title: "Proyectos de complejidad baja",
          text: "50 % al inicio y 50 % a la entrega.",
        },
        {
          title: "Proyectos de complejidad media",
          text: "40 % al inicio, 30 % durante el desarrollo y 30 % a la entrega.",
        },
        {
          title: "Proyectos de complejidad alta",
          text: "30 % al inicio, 30 % durante el desarrollo, 25 % durante la fase de pruebas y 15 % a la entrega.",
        },
        {
          title: "Proyectos de complejidad muy alta o estratégicos",
          text: "25 % al inicio y tres pagos adicionales del 25 % vinculados a los correspondientes hitos del proyecto.",
        },
        {
          title: "Proyectos excepcionales",
          text: "Cuando las características particulares de un proyecto lo justifiquen, MODIRA podrá establecer una estructura de pagos específica y adaptada a dicho proyecto.",
        },
      ],
      afterPaymentPlans: [
        "En estos casos, la estructura concreta será comunicada al cliente y deberá ser aceptada previamente como parte de las condiciones del presupuesto o documento contractual correspondiente.",
        "Las estructuras anteriores tienen carácter orientativo y podrán adaptarse a las características concretas de cada proyecto. La estructura finalmente aplicable será siempre la que figure expresamente en el presupuesto aceptado.",
      ],
      subsections: [
        {
          title: "30.1. Determinación previa de la estructura de pagos",
          paragraphs: [
            "La clasificación del proyecto y la estructura de pagos correspondiente serán determinadas por MODIRA antes de la contratación.",
            "El presupuesto deberá indicar, cuando corresponda:",
          ],
          bullets: [
            "el importe total del proyecto;",
            "los impuestos aplicables;",
            "el porcentaje correspondiente a cada pago;",
            "el importe de cada pago;",
            "la fase o hito que da lugar a cada pago;",
            "el momento o condición de vencimiento de cada pago;",
            "cualquier condición particular relacionada con la facturación.",
          ],
          afterBullets: [
            "El cliente podrá conocer estas condiciones antes de aceptar el presupuesto.",
            "Una vez aceptado el presupuesto, la estructura de pagos y los hitos asociados quedarán fijados para el proyecto.",
            "MODIRA no podrá modificar unilateralmente los porcentajes, importes o hitos establecidos en un presupuesto ya aceptado, salvo que exista una modificación del proyecto aceptada por ambas partes o una causa legal o contractual que permita dicha modificación.",
          ],
        },
        {
          title: "30.2. Pagos vinculados a hitos",
          paragraphs: [
            "Cuando un pago esté vinculado a un hito, su exigibilidad quedará asociada al cumplimiento de la fase, entrega o condición definida en el presupuesto o en la documentación contractual correspondiente.",
            "Los hitos deberán describirse de forma suficientemente clara para permitir determinar cuándo se ha alcanzado la fase correspondiente.",
            "Un hito podrá consistir, entre otros, en:",
          ],
          bullets: [
            "finalización de una fase de análisis;",
            "finalización de una fase de desarrollo;",
            "implementación de una funcionalidad;",
            "disponibilidad de una automatización para pruebas;",
            "finalización de una fase de pruebas;",
            "entrega de documentación;",
            "puesta a disposición de una solución;",
            "entrega final del proyecto.",
          ],
          afterBullets: [
            "Los criterios concretos de cumplimiento de cada hito serán los establecidos en el presupuesto o documentación contractual.",
            "Cuando se alcance un hito conforme a los criterios establecidos, MODIRA podrá emitir la factura correspondiente.",
          ],
        },
        {
          title: "30.3. Pagos iniciales",
          paragraphs: [
            "Cuando el presupuesto establezca un pago inicial, dicho pago constituirá la primera parte del precio total del proyecto y estará vinculado al inicio o preparación de los trabajos contratados.",
            "El pago inicial podrá destinarse, entre otras actuaciones, a la reserva de recursos, planificación, análisis, preparación técnica, adquisición o configuración de recursos necesarios y comienzo de los trabajos.",
            "La existencia de un pago inicial no implica que el proyecto haya sido ejecutado íntegramente ni que el resto del precio sea exigible antes de los hitos establecidos.",
          ],
        },
        {
          title: "30.4. Modificaciones y ampliaciones del proyecto",
          paragraphs: [
            "Si el cliente solicita modificaciones, ampliaciones o nuevas funcionalidades que excedan del alcance inicialmente contratado, MODIRA podrá evaluar su impacto sobre:",
          ],
          bullets: [
            "precio;",
            "duración;",
            "complejidad;",
            "recursos necesarios;",
            "riesgos;",
            "estructura de pagos.",
          ],
          afterBullets: [
            "Cuando la modificación exceda del alcance contratado, MODIRA podrá emitir un nuevo presupuesto o una modificación presupuestaria con su correspondiente estructura de pagos.",
            "Los trabajos adicionales no comenzarán hasta que el cliente haya aceptado las nuevas condiciones, salvo que las partes hayan acordado expresamente otro procedimiento.",
            "La aceptación de una modificación podrá implicar la actualización de los hitos y de los pagos pendientes cuando resulte necesario.",
          ],
        },
        {
          title: "30.5. Finalidad de la distribución por hitos",
          paragraphs: [
            "La distribución del precio mediante pagos asociados a diferentes fases o hitos tiene como finalidad distribuir de forma equilibrada la contraprestación económica a lo largo del proyecto, teniendo en cuenta la duración, complejidad y exposición de recursos que pueda asumir MODIRA.",
            "Este sistema permite que el coste económico del proyecto se distribuya entre las distintas fases de ejecución, evitando que MODIRA tenga que asumir íntegramente durante períodos prolongados los recursos y costes asociados a proyectos de larga duración o elevada complejidad antes de recibir la correspondiente contraprestación.",
            "La distribución por hitos no modifica el precio total acordado para el proyecto, sino únicamente la forma y momento en que dicho precio se abona.",
          ],
        },
      ],
    },

    {
      id: "stripe",
      number: "31",
      title: "Pagos mediante Stripe",
      paragraphs: [
        "MODIRA utiliza Stripe para gestionar determinados pagos de facturas.",
        "Cuando una factura disponga de pago mediante Stripe, el cliente podrá acceder al flujo de pago correspondiente.",
        "MODIRA no almacena directamente los datos completos de la tarjeta utilizados para realizar el pago.",
        "El procesamiento del pago se realiza mediante la infraestructura de Stripe.",
        "La información sobre los datos personales tratados en relación con los pagos se encuentra desarrollada en la Política de Privacidad.",
      ],
    },

    {
      id: "facturas",
      number: "32",
      title: "Facturas",
      paragraphs: [
        "Las facturas emitidas por MODIRA podrán estar disponibles desde el Área de Cliente cuando dicha funcionalidad esté habilitada para el usuario.",
        "Las facturas podrán incluir los datos fiscales y económicos necesarios conforme a la normativa aplicable.",
        "Los registros de pagos y facturación podrán conservarse durante los períodos establecidos en la Política de Privacidad y en la normativa aplicable.",
      ],
    },

    {
      id: "impago",
      number: "33",
      title: "Impago",
      paragraphs: [
        "Cuando una factura haya vencido y permanezca impagada, MODIRA podrá reclamar el importe pendiente conforme a la legislación aplicable y a las condiciones particulares del contrato.",
        "Cuando resulte procedente conforme a la normativa aplicable a las operaciones comerciales, el retraso en el pago podrá generar intereses de demora y, en su caso, los costes de cobro legalmente procedentes.",
        "Cuando resulte necesario, MODIRA podrá suspender determinados trabajos, servicios o funcionalidades cuya continuidad dependa del cumplimiento de las obligaciones de pago vencidas, sin perjuicio de los derechos que correspondan a las partes conforme al contrato y a la legislación aplicable.",
        "La suspensión por impago no supondrá automáticamente la resolución del contrato, salvo que corresponda conforme a las condiciones contratadas o a la legislación aplicable.",
        "La falta de pago de un hito no convierte automáticamente en vencidos todos los pagos futuros del proyecto, salvo que así se haya establecido expresamente en el presupuesto, contrato o resulte legalmente procedente.",
      ],
    },

    {
      id: "responsabilidad-cliente",
      number: "34",
      title: "Responsabilidad del cliente",
      paragraphs: [
        "El cliente será responsable de:",
      ],
      bullets: [
        "la exactitud de la información proporcionada;",
        "disponer de los derechos necesarios sobre los materiales entregados;",
        "disponer de autorización para proporcionar datos de terceros;",
        "mantener sus credenciales seguras;",
        "utilizar MODIRA legalmente;",
        "revisar los resultados de automatizaciones e integraciones;",
        "mantener actualizados los accesos y credenciales que dependan de él;",
        "realizar las comprobaciones necesarias antes de utilizar resultados automatizados en procesos relevantes.",
      ],
    },

    {
      id: "limitacion",
      number: "35",
      title: "Limitación de responsabilidad",
      paragraphs: [
        "MODIRA responderá de acuerdo con la legislación aplicable.",
        "No obstante, MODIRA no será responsable de daños derivados de circunstancias que no dependan razonablemente de su actuación, incluyendo, cuando corresponda:",
      ],
      bullets: [
        "interrupciones o fallos de servicios de terceros;",
        "cambios de APIs;",
        "indisponibilidad de herramientas externas;",
        "errores derivados de información incorrecta proporcionada por el cliente;",
        "modificaciones realizadas por el cliente o terceros;",
        "uso de las automatizaciones fuera del alcance contratado;",
        "decisiones empresariales adoptadas por el cliente a partir de información proporcionada por MODIRA AI;",
        "acontecimientos de fuerza mayor.",
      ],
      afterBullets: [
        "Nada de lo establecido en estos Términos pretende excluir o limitar responsabilidades que legalmente no puedan excluirse o limitarse.",
      ],
    },

    {
      id: "confidencialidad",
      number: "36",
      title: "Confidencialidad",
      paragraphs: [
        "MODIRA tratará como confidencial la información que el cliente proporcione en el marco de la relación profesional cuando, por su naturaleza, deba considerarse confidencial.",
        "El acceso interno a la información estará limitado a las personas autorizadas que necesiten acceder a ella para desarrollar sus funciones.",
        "Cuando resulte aplicable, podrán establecerse obligaciones adicionales de confidencialidad mediante contrato específico.",
      ],
    },

    {
      id: "proteccion-datos",
      number: "37",
      title: "Protección de datos",
      paragraphs: [
        "El tratamiento de datos personales realizado por MODIRA se regula mediante su Política de Privacidad.",
        "Cuando MODIRA actúe como responsable del tratamiento, aplicará las condiciones descritas en dicha Política.",
        "Cuando MODIRA trate datos personales por cuenta de una empresa cliente, las partes formalizarán el correspondiente Acuerdo de Encargo del Tratamiento (DPA) cuando resulte legalmente necesario.",
        "La Política de Privacidad y el DPA regulan específicamente cuestiones como:",
      ],
      bullets: [
        "categorías de datos;",
        "finalidades;",
        "bases jurídicas;",
        "conservación;",
        "proveedores;",
        "transferencias internacionales;",
        "derechos;",
        "seguridad;",
        "tratamiento mediante inteligencia artificial.",
      ],
    },

    {
      id: "cookies",
      number: "38",
      title: "Cookies",
      paragraphs: [
        "El uso de cookies y tecnologías similares en la web de MODIRA se regula mediante la Política de Cookies.",
        "La aceptación de estos Términos no implica por sí misma el consentimiento para cookies que requieran consentimiento.",
      ],
    },

    {
      id: "comunicaciones-comerciales",
      number: "39",
      title: "Comunicaciones comerciales",
      paragraphs: [
        "MODIRA podrá realizar comunicaciones relacionadas directamente con la prestación de servicios, cuentas, proyectos, facturación, seguridad y otras cuestiones operativas.",
        "Las comunicaciones comerciales estarán sujetas a la normativa aplicable y, cuando sea necesario, requerirán el consentimiento correspondiente.",
        "El consentimiento para recibir comunicaciones comerciales será independiente de la aceptación de estos Términos.",
      ],
    },

    {
      id: "modificaciones-terminos",
      number: "40",
      title: "Modificaciones de los Términos",
      paragraphs: [
        "MODIRA podrá modificar estos Términos cuando resulte necesario por:",
      ],
      bullets: [
        "cambios legales;",
        "cambios tecnológicos;",
        "incorporación o modificación de servicios;",
        "cambios en la plataforma;",
        "modificaciones en los sistemas de contratación;",
        "cambios en proveedores;",
        "necesidades de seguridad;",
        "otras circunstancias que hagan necesaria su actualización.",
      ],
      afterBullets: [
        "La versión vigente estará disponible en la web.",
        "Las modificaciones que afecten a contratos ya celebrados no alterarán unilateralmente sus condiciones esenciales, salvo cuando exista una base legal o contractual que permita dicha modificación.",
        "Cuando una modificación requiera una nueva aceptación, MODIRA podrá solicitarla antes de continuar utilizando determinadas funcionalidades.",
      ],
    },

    {
      id: "duracion",
      number: "41",
      title: "Duración y terminación",
      paragraphs: [
        "La relación contractual tendrá la duración establecida en el presupuesto, contrato o condiciones particulares correspondientes.",
        "Los servicios puntuales finalizarán cuando se hayan completado las prestaciones contratadas, sin perjuicio de las obligaciones que deban permanecer vigentes.",
        "Los servicios de mantenimiento tendrán la duración y periodicidad establecidas en el plan contratado.",
        "La finalización de una relación contractual no afectará a aquellas obligaciones que por su naturaleza deban continuar vigentes, incluyendo obligaciones de pago, confidencialidad, propiedad intelectual, protección de datos y conservación de documentación.",
      ],
    },

    {
      id: "resolucion",
      number: "42",
      title: "Resolución de la relación contractual",
      paragraphs: [
        "La relación contractual podrá finalizar:",
      ],
      bullets: [
        "por cumplimiento de las prestaciones;",
        "por acuerdo entre las partes;",
        "por cancelación conforme a las condiciones del proyecto;",
        "por incumplimiento contractual;",
        "por impago;",
        "por cualquier otra causa prevista legal o contractualmente.",
      ],
      afterBullets: [
        "Cuando exista un incumplimiento susceptible de subsanación, la parte afectada podrá solicitar su corrección antes de resolver el contrato cuando resulte razonable y conforme a la legislación aplicable.",
      ],
    },

    {
      id: "fuerza-mayor",
      number: "43",
      title: "Fuerza mayor",
      paragraphs: [
        "MODIRA no será responsable por incumplimientos o retrasos causados por acontecimientos imprevisibles o inevitables que estén fuera de su control razonable.",
        "Entre otros, podrán considerarse circunstancias de esta naturaleza determinados:",
      ],
      bullets: [
        "fallos generalizados de infraestructura;",
        "interrupciones de proveedores;",
        "ataques o incidentes de gran alcance;",
        "desastres naturales;",
        "interrupciones de comunicaciones;",
        "actos de autoridad;",
        "conflictos;",
        "situaciones extraordinarias que impidan razonablemente prestar el servicio.",
      ],
      afterBullets: [
        "MODIRA adoptará medidas razonables para reducir las consecuencias y restablecer la prestación cuando sea posible.",
      ],
    },

    {
      id: "nulidad",
      number: "44",
      title: "Nulidad parcial",
      paragraphs: [
        "Si alguna disposición de estos Términos fuese declarada inválida, ilegal o inaplicable, dicha circunstancia no afectará al resto de las disposiciones.",
        "La disposición afectada se interpretará o sustituirá, cuando legalmente proceda, de forma que se aproxime lo máximo posible a la finalidad económica y jurídica perseguida, respetando la legislación aplicable.",
      ],
    },

    {
      id: "no-renuncia",
      number: "45",
      title: "No renuncia",
      paragraphs: [
        "El hecho de que MODIRA no ejerza inmediatamente un derecho previsto en estos Términos no supondrá una renuncia a dicho derecho.",
      ],
    },

    {
      id: "relacion-documentos",
      number: "46",
      title: "Relación entre documentos contractuales",
      paragraphs: [
        "La relación entre MODIRA y el cliente podrá estar regulada conjuntamente por:",
      ],
      numbered: [
        "estos Términos y Condiciones;",
        "el presupuesto aceptado;",
        "las condiciones particulares del proyecto;",
        "el contrato específico que, en su caso, se formalice;",
        "el Acuerdo de Encargo del Tratamiento, cuando corresponda.",
      ],
      afterNumbered: [
        "En caso de contradicción entre documentos, las condiciones particulares expresamente aceptadas para un proyecto prevalecerán sobre las condiciones generales únicamente respecto de aquello que regulen específicamente.",
        "La Política de Privacidad y la Política de Cookies tienen una finalidad informativa y regulatoria específica en materia de protección de datos y tecnologías similares y no sustituyen las condiciones económicas y contractuales del proyecto.",
      ],
    },

    {
      id: "legislacion",
      number: "47",
      title: "Legislación aplicable",
      paragraphs: [
        "Estos Términos se regirán por la legislación española.",
        "La contratación electrónica se regirá, entre otras normas aplicables, por la Ley 34/2002, de Servicios de la Sociedad de la Información y de Comercio Electrónico, así como por las normas civiles y mercantiles que correspondan.",
        "En materia de protección de datos será de aplicación la normativa correspondiente, incluyendo el Reglamento (UE) 2016/679 y la Ley Orgánica 3/2018.",
      ],
    },

    {
      id: "conflictos",
      number: "48",
      title: "Resolución de conflictos y jurisdicción",
      paragraphs: [
        "MODIRA procurará resolver de forma amistosa cualquier discrepancia relacionada con sus servicios.",
        "Cuando ambas partes actúen como empresarios o profesionales en el marco de su actividad económica, las controversias se someterán a los juzgados y tribunales que resulten competentes conforme a la legislación aplicable.",
        "Nada de esta cláusula pretende alterar las reglas imperativas de competencia judicial que puedan resultar aplicables en cada caso.",
      ],
    },

    {
      id: "contacto",
      number: "49",
      title: "Contacto",
      paragraphs: [
        "Para cuestiones relacionadas con estos Términos y Condiciones, el cliente puede contactar con MODIRA mediante:",
      ],
      info: [
        ["Email", "info@modira.es"],
      ],
      afterInfo: [
        "También podrá utilizar los canales de soporte disponibles dentro del Área de Cliente cuando se trate de una incidencia o cuestión relacionada con un servicio contratado.",
      ],
    },

    {
      id: "version",
      number: "50",
      title: "Versión",
      info: [
        ["Versión", "1.0"],
        ["Fecha de elaboración", "14 de septiembre de 2026"],
        ["Fecha de entrada en vigor", "[FECHA DE PUBLICACIÓN]"],
      ],
    },
     {
      id: "identificacion",
      number: "51",
      title: "Identificación del titular",
      paragraphs: [
        "Los presentes Términos y Condiciones regulan el acceso y utilización de MODIRA y, cuando corresponda, la relación contractual derivada de la contratación de sus servicios.",
      ],
      info: [
        ["Correo electrónico", "info@modira.es"],
        ["Sitio web", "https://modira.es"],
        ["Marca", "MODIRA"],
        ["Titular / prestador", "Adrián Modino Merino"],
        ["NIF", "06641212P"],
        ["Domicilio", "Calle Lisboa 25, 28670, Villaviciosa de Odón, Madrid, España"],
        
      ],
      afterInfo: [
        "MODIRA es una marca/proyecto titularidad de Adrián Modino Merino.",
        "La información completa relativa a la identidad del titular y a la responsabilidad sobre el sitio web se encuentra asimismo disponible en el Aviso Legal de MODIRA.",
      ],
    },
  ];

  return (
    <div
      className={`min-h-screen bg-[#F8FAFC] terms-page ${
        isScrolled
          ? "terms-scrolled"
          : "terms-top"
      }`}
    >
      {/* ========================================================
          HEADER
          ======================================================== */}

      <div
        className={`terms-header-wrapper ${
          isScrolled
            ? "terms-header-scrolled"
            : "terms-header-transparent"
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
                  <FileText
                    size={24}
                    className="text-[#1E3A8A]"
                  />
                </div>

                <div>
                  <h1 className="text-4xl md:text-5xl font-bold tracking-tight text-[#1E3A8A] mb-5">
                    Términos y Condiciones
                  </h1>

                  <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
                    Condiciones que regulan el acceso y utilización de
                    MODIRA, así como las condiciones aplicables a la
                    contratación y prestación de sus servicios.
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

      <main className="container-lg mx-auto px-6 md:px-10 lg:px-12 py-14 md:py-20">
        <div className="max-w-6xl mx-auto">

          <div className="grid lg:grid-cols-[240px_minmax(0,1fr)] gap-10 lg:gap-16">

            {/* ==================================================
                ÍNDICE
                ================================================== */}

            <aside className="hidden lg:block">
              <div className="sticky top-28">
                <p className="text-xs font-semibold uppercase tracking-wider text-gray-400 mb-4">
                  Contenido
                </p>

                <nav className="space-y-1 max-h-[calc(100vh-160px)] overflow-y-auto pr-2">
                  {sections.map((section) => (
                    <a
                      key={section.id}
                      href={`#${section.id}`}
                      className="group flex items-start gap-2 py-1.5 text-xs text-gray-500 hover:text-[#1E3A8A] transition-colors"
                    >
                      <span className="w-6 flex-shrink-0 text-gray-400 group-hover:text-[#1E3A8A]">
                        {section.number}.
                      </span>

                      <span className="leading-relaxed">
                        {section.title}
                      </span>
                    </a>
                  ))}
                </nav>
              </div>
            </aside>

            {/* ==================================================
                DOCUMENTO
                ================================================== */}

            <div className="min-w-0">
              <article className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="px-6 py-8 md:px-10 md:py-12 lg:px-14">

                  {/* Intro */}

                  <div className="pb-10 mb-10 border-b border-gray-100">
                    <p className="text-sm leading-7 text-gray-500">
                      Los presentes Términos y Condiciones constituyen
                      las condiciones generales aplicables al acceso y
                      utilización de MODIRA y, cuando corresponda, a la
                      contratación de sus servicios.
                    </p>
                  </div>

                  {/* Sections */}

                  <div className="space-y-14">
                    {sections.map((section) => (
                      <section
                        key={section.id}
                        id={section.id}
                        className="scroll-mt-28"
                      >
                        <div className="flex items-start gap-4 mb-5">
                          <div className="flex-shrink-0 w-9 h-9 rounded-lg bg-[#EFF6FF] flex items-center justify-center">
                            <span className="text-xs font-bold text-[#1E3A8A]">
                              {section.number}
                            </span>
                          </div>

                          <h2 className="text-xl md:text-2xl font-bold text-[#1E3A8A] leading-tight pt-1">
                            {section.title}
                          </h2>
                        </div>

                        <div className="pl-0 md:pl-[52px] space-y-5">

                          {section.paragraphs?.map(
                            (paragraph, index) => (
                              <p
                                key={index}
                                className="text-[15px] md:text-base text-gray-600 leading-7"
                              >
                                {paragraph}
                              </p>
                            )
                          )}

                          {/* Information blocks */}

                          {section.info && (
                            <div className="rounded-xl border border-gray-100 bg-[#F8FAFC] overflow-hidden">
                              {section.info.map(
                                ([label, value], index) => (
                                  <div
                                    key={label}
                                    className={`grid sm:grid-cols-[190px_1fr] gap-2 sm:gap-6 px-5 py-4 ${
                                      index !== section.info!.length - 1
                                        ? "border-b border-gray-100"
                                        : ""
                                    }`}
                                  >
                                    <span className="text-sm font-semibold text-gray-700">
                                      {label}
                                    </span>

                                    <span className="text-sm text-gray-500 break-words">
                                      {value}
                                    </span>
                                  </div>
                                )
                              )}
                            </div>
                          )}

                          {/* Bullets */}

                          {section.bullets && (
                            <ul className="space-y-3">
                              {section.bullets.map(
                                (bullet, index) => (
                                  <li
                                    key={index}
                                    className="flex items-start gap-3 text-[15px] md:text-base text-gray-600 leading-7"
                                  >
                                    <span className="mt-[11px] w-1.5 h-1.5 rounded-full bg-[#1E3A8A] flex-shrink-0" />
                                    <span>{bullet}</span>
                                  </li>
                                )
                              )}
                            </ul>
                          )}

                          {section.afterBullets?.map(
                            (paragraph, index) => (
                              <p
                                key={index}
                                className="text-[15px] md:text-base text-gray-600 leading-7"
                              >
                                {paragraph}
                              </p>
                            )
                          )}

                          {/* Segundo bloque de bullets */}

                          {section.bullets2 && (
                            <ul className="space-y-3">
                              {section.bullets2.map(
                                (bullet, index) => (
                                  <li
                                    key={index}
                                    className="flex items-start gap-3 text-[15px] md:text-base text-gray-600 leading-7"
                                  >
                                    <span className="mt-[11px] w-1.5 h-1.5 rounded-full bg-[#1E3A8A] flex-shrink-0" />
                                    <span>{bullet}</span>
                                  </li>
                                )
                              )}
                            </ul>
                          )}

                          {section.afterBullets2?.map(
                            (paragraph, index) => (
                              <p
                                key={index}
                                className="text-[15px] md:text-base text-gray-600 leading-7"
                              >
                                {paragraph}
                              </p>
                            )
                          )}

                          {/* Numeración */}

                          {section.numbered && (
                            <ol className="space-y-3 list-decimal list-outside ml-5">
                              {section.numbered.map(
                                (item, index) => (
                                  <li
                                    key={index}
                                    className="pl-2 text-[15px] md:text-base text-gray-600 leading-7"
                                  >
                                    {item}
                                  </li>
                                )
                              )}
                            </ol>
                          )}

                          {section.afterNumbered?.map(
                            (paragraph, index) => (
                              <p
                                key={index}
                                className="text-[15px] md:text-base text-gray-600 leading-7"
                              >
                                {paragraph}
                              </p>
                            )
                          )}

                          {/* Subapartados */}

                          {section.subheadings?.map(
                            (subsection, index) => (
                              <div
                                key={index}
                                className="space-y-4 pt-3"
                              >
                                <h3 className="text-base md:text-lg font-semibold text-gray-800">
                                  {subsection.title}
                                </h3>

                                {subsection.paragraphs?.map(
                                  (paragraph, paragraphIndex) => (
                                    <p
                                      key={paragraphIndex}
                                      className="text-[15px] md:text-base text-gray-600 leading-7"
                                    >
                                      {paragraph}
                                    </p>
                                  )
                                )}
                              </div>
                            )
                          )}

                          {/* Planes de pago */}

                          {section.paymentPlans && (
                            <div className="grid gap-4">
                              {section.paymentPlans.map(
                                (plan, index) => (
                                  <div
                                    key={index}
                                    className="rounded-xl border border-gray-100 bg-[#F8FAFC] p-5"
                                  >
                                    <div className="flex items-start gap-3">
                                      <ChevronRight
                                        size={18}
                                        className="text-[#1E3A8A] mt-0.5 flex-shrink-0"
                                      />

                                      <div>
                                        <h3 className="text-sm md:text-base font-semibold text-gray-800 mb-1">
                                          {plan.title}
                                        </h3>

                                        <p className="text-sm md:text-[15px] text-gray-500 leading-6">
                                          {plan.text}
                                        </p>
                                      </div>
                                    </div>
                                  </div>
                                )
                              )}
                            </div>
                          )}

                          {section.afterPaymentPlans?.map(
                            (paragraph, index) => (
                              <p
                                key={index}
                                className="text-[15px] md:text-base text-gray-600 leading-7"
                              >
                                {paragraph}
                              </p>
                            )
                          )}

                          {/* Subapartados numerados de la sección 31 */}

                          {section.subsections?.map(
                            (subsection, index) => (
                              <div
                                key={index}
                                className="pt-6 mt-6 border-t border-gray-100 space-y-4"
                              >
                                <h3 className="text-base md:text-lg font-semibold text-[#1E3A8A]">
                                  {subsection.title}
                                </h3>

                                {subsection.paragraphs?.map(
                                  (paragraph, paragraphIndex) => (
                                    <p
                                      key={paragraphIndex}
                                      className="text-[15px] md:text-base text-gray-600 leading-7"
                                    >
                                      {paragraph}
                                    </p>
                                  )
                                )}

                                {subsection.bullets && (
                                  <ul className="space-y-3">
                                    {subsection.bullets.map(
                                      (bullet, bulletIndex) => (
                                        <li
                                          key={bulletIndex}
                                          className="flex items-start gap-3 text-[15px] md:text-base text-gray-600 leading-7"
                                        >
                                          <span className="mt-[11px] w-1.5 h-1.5 rounded-full bg-[#1E3A8A] flex-shrink-0" />
                                          <span>{bullet}</span>
                                        </li>
                                      )
                                    )}
                                  </ul>
                                )}

                                {subsection.afterBullets?.map(
                                  (paragraph, paragraphIndex) => (
                                    <p
                                      key={paragraphIndex}
                                      className="text-[15px] md:text-base text-gray-600 leading-7"
                                    >
                                      {paragraph}
                                    </p>
                                  )
                                )}
                              </div>
                            )
                          )}
                        </div>
                      </section>
                    ))}
                  </div>

                  {/* ==================================================
                      FINAL
                      ================================================== */}

                  <div className="mt-16 pt-8 border-t border-gray-100">
                    <p className="text-sm text-gray-400 leading-6">
                      Versión 1.0 · Elaborado el 13 de septiembre de 2026.
                    </p>
                  </div>

                </div>
              </article>
            </div>
          </div>
        </div>
      </main>
      <style>{`
  /*
   * ========================================================
   * MODIRA — HEADER DE TÉRMINOS Y CONDICIONES
   * ========================================================
   *
   * ARRIBA DEL TODO
   * ----------------
   * Header azul.
   *
   * AL HACER SCROLL
   * ----------------
   * Header blanco.
   *
   * ========================================================
   */

  .terms-header-wrapper {
    position: relative;
    z-index: 50;
    min-height: 0;
    transition:
      background-color 250ms ease,
      box-shadow 250ms ease;
  }

  /*
   * ========================================================
   * ESTADO INICIAL — AZUL
   * ========================================================
   */

  .terms-header-transparent {
    background: linear-gradient(
      to right,
      #102A66,
      #173B8F
    ) !important;

    box-shadow:
      0 4px 12px rgba(16, 42, 102, 0.18) !important;
  }

  .terms-header-transparent header {
    background: linear-gradient(
      to right,
      #102A66,
      #173B8F
    ) !important;

    box-shadow: none !important;
  }

  /*
   * ========================================================
   * ESTADO CON SCROLL — BLANCO
   * ========================================================
   */

  .terms-header-scrolled {
    background-color: #ffffff !important;
    box-shadow:
      0 1px 0 rgba(15, 23, 42, 0.06) !important;
  }

  .terms-header-scrolled header {
    background-color: #ffffff !important;
    box-shadow: none !important;
  }

  /*
   * ========================================================
   * PÁGINA
   * ========================================================
   */

  .terms-page {
    position: relative;
  }
`}</style>
    </div>
  );
}