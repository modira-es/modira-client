import { useEffect, useState } from "react";
import Header from "@/components/Header";
import {
  ArrowLeft,
  FileText,
} from "lucide-react";

/*
 * ============================================================
 * MODIRA — POLÍTICA DE PRIVACIDAD
 * ============================================================
 *
 * Diseño y estructura adaptados de la página de
 * Términos y Condiciones de MODIRA.
 *
 * El contenido jurídico se corresponde con el documento
 * "POLÍTICA DE PRIVACIDAD DE MODIRA".
 * ============================================================
 */

type Block =
  | { type: "p"; text: string }
  | { type: "bullet"; text: string }
  | { type: "numbered"; text: string }
  | { type: "subheading"; text: string }
  | { type: "label"; text: string }
  | { type: "info" }
  | { type: "info2" };

type Section = {
  id: string;
  number: string;
  title: string;
  blocks: Block[];
  info?: [string, string][];
  dpd?: string;
  table?: [string, string][];
  table_header?: [string, string];
};

const sections: Section[] = [
  
  {
    "id": "ambito-de-esta-politica-1",
    "number": "1",
    "title": "Ámbito de esta Política",
    "blocks": [
      {
        "type": "p",
        "text": "Esta Política se aplica a los tratamientos de datos personales realizados por MODIRA en relación con:"
      },
      {
        "type": "bullet",
        "text": "la navegación y utilización del sitio web;"
      },
      {
        "type": "bullet",
        "text": "la creación y gestión de cuentas;"
      },
      {
        "type": "bullet",
        "text": "la prestación de los servicios de MODIRA;"
      },
      {
        "type": "bullet",
        "text": "la gestión de empresas y usuarios;"
      },
      {
        "type": "bullet",
        "text": "proyectos, presupuestos, contratos y documentación asociada;"
      },
      {
        "type": "bullet",
        "text": "facturación y pagos;"
      },
      {
        "type": "bullet",
        "text": "solicitudes de auditoría;"
      },
      {
        "type": "bullet",
        "text": "solicitudes de soporte;"
      },
      {
        "type": "bullet",
        "text": "comunicaciones con MODIRA;"
      },
      {
        "type": "bullet",
        "text": "MODIRA AI;"
      },
      {
        "type": "bullet",
        "text": "seguridad y prevención del fraude o abuso;"
      },
      {
        "type": "bullet",
        "text": "gestión de derechos de protección de datos;"
      },
      {
        "type": "bullet",
        "text": "análisis estadístico mediante tecnologías sujetas a consentimiento."
      },
      {
        "type": "p",
        "text": "El tratamiento de cookies y tecnologías similares se desarrolla adicionalmente en la Política de Cookies de MODIRA."
      }
    ]
  },
  {
    "id": "que-datos-personales-puede-tratar-2",
    "number": "2",
    "title": "Qué datos personales puede tratar MODIRA",
    "blocks": [
      {
        "type": "p",
        "text": "Dependiendo de la utilización que realice cada persona de MODIRA, pueden tratarse las siguientes categorías:"
      },
      {
        "type": "label",
        "text": "Datos identificativos y de contacto"
      },
      {
        "type": "bullet",
        "text": "nombre;"
      },
      {
        "type": "bullet",
        "text": "dirección de correo electrónico;"
      },
      {
        "type": "bullet",
        "text": "número de teléfono, cuando sea facilitado;"
      },
      {
        "type": "bullet",
        "text": "datos de empresa asociados a la cuenta;"
      },
      {
        "type": "bullet",
        "text": "identificadores internos de usuario y empresa."
      },
      {
        "type": "label",
        "text": "Datos de cuenta"
      },
      {
        "type": "bullet",
        "text": "información necesaria para registrar y gestionar la cuenta;"
      },
      {
        "type": "bullet",
        "text": "información relacionada con la autenticación;"
      },
      {
        "type": "bullet",
        "text": "fechas de registro y actividad de la cuenta;"
      },
      {
        "type": "bullet",
        "text": "estado de la cuenta;"
      },
      {
        "type": "bullet",
        "text": "información técnica necesaria para gestionar sesiones y seguridad."
      },
      {
        "type": "p",
        "text": "MODIRA utiliza Supabase Auth para la autenticación y gestión de cuentas y no almacena las contraseñas en sus propias tablas de aplicación. El sistema de autenticación aplica mecanismos de protección específicos para registro, inicio de sesión y recuperación de contraseña."
      },
      {
        "type": "label",
        "text": "Datos profesionales y empresariales"
      },
      {
        "type": "p",
        "text": "Pueden tratarse datos relativos a:"
      },
      {
        "type": "bullet",
        "text": "empresa;"
      },
      {
        "type": "bullet",
        "text": "actividad o sector;"
      },
      {
        "type": "bullet",
        "text": "proyectos;"
      },
      {
        "type": "bullet",
        "text": "presupuestos;"
      },
      {
        "type": "bullet",
        "text": "servicios contratados;"
      },
      {
        "type": "bullet",
        "text": "información necesaria para prestar los servicios."
      },
      {
        "type": "label",
        "text": "Datos económicos y de facturación"
      },
      {
        "type": "p",
        "text": "Pueden incluir:"
      },
      {
        "type": "bullet",
        "text": "datos de facturas;"
      },
      {
        "type": "bullet",
        "text": "importes;"
      },
      {
        "type": "bullet",
        "text": "IVA;"
      },
      {
        "type": "bullet",
        "text": "IRPF cuando corresponda;"
      },
      {
        "type": "bullet",
        "text": "estado de las facturas;"
      },
      {
        "type": "bullet",
        "text": "información relativa a pagos;"
      },
      {
        "type": "bullet",
        "text": "identificadores de operaciones de pago."
      },
      {
        "type": "label",
        "text": "Datos de soporte y actividad"
      },
      {
        "type": "p",
        "text": "MODIRA puede tratar:"
      },
      {
        "type": "bullet",
        "text": "solicitudes y tickets de soporte;"
      },
      {
        "type": "bullet",
        "text": "descripción de incidencias;"
      },
      {
        "type": "bullet",
        "text": "prioridad y estado;"
      },
      {
        "type": "bullet",
        "text": "información asociada a proyectos;"
      },
      {
        "type": "bullet",
        "text": "registros de actividad necesarios para seguridad, trazabilidad y funcionamiento del servicio."
      },
      {
        "type": "label",
        "text": "Datos introducidos voluntariamente"
      },
      {
        "type": "p",
        "text": "Los campos de texto, solicitudes de auditoría, tickets, proyectos y funcionalidades de inteligencia artificial pueden permitir que el usuario introduzca información adicional."
      },
      {
        "type": "p",
        "text": "El usuario debe evitar introducir información personal innecesaria, especialmente datos personales de terceros o categorías especiales de datos."
      }
    ]
  },
  {
    "id": "finalidades-del-tratamiento-3",
    "number": "3",
    "title": "Finalidades del tratamiento",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA tratará los datos personales para las siguientes finalidades."
      },
      {
        "type": "subheading",
        "text": "Gestión de cuentas y acceso"
      },
      {
        "type": "p",
        "text": "Para:"
      },
      {
        "type": "bullet",
        "text": "crear y administrar cuentas;"
      },
      {
        "type": "bullet",
        "text": "autenticar usuarios;"
      },
      {
        "type": "bullet",
        "text": "mantener sesiones;"
      },
      {
        "type": "bullet",
        "text": "recuperar cuentas;"
      },
      {
        "type": "bullet",
        "text": "mantener la seguridad del acceso;"
      },
      {
        "type": "bullet",
        "text": "gestionar estados de cuenta;"
      },
      {
        "type": "bullet",
        "text": "impedir accesos de cuentas bloqueadas."
      },
      {
        "type": "p",
        "text": "La base jurídica será, según corresponda, la ejecución del contrato o la aplicación de medidas precontractuales solicitadas por el interesado."
      }
    ]
  },
  {
    "id": "prestaci-n-de-los-servicios-4",
    "number": "4",
    "title": "Prestación de los servicios",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA tratará los datos necesarios para:"
      },
      {
        "type": "bullet",
        "text": "gestionar empresas;"
      },
      {
        "type": "bullet",
        "text": "gestionar usuarios;"
      },
      {
        "type": "bullet",
        "text": "prestar servicios contratados;"
      },
      {
        "type": "bullet",
        "text": "gestionar proyectos;"
      },
      {
        "type": "bullet",
        "text": "gestionar documentación;"
      },
      {
        "type": "bullet",
        "text": "elaborar y responder presupuestos;"
      },
      {
        "type": "bullet",
        "text": "gestionar contratos;"
      },
      {
        "type": "bullet",
        "text": "gestionar incidencias y soporte."
      },
      {
        "type": "p",
        "text": "La base jurídica será principalmente la ejecución del contrato o la adopción de medidas precontractuales."
      },
      {
        "type": "p",
        "text": "Cuando MODIRA trate datos personales por cuenta de una empresa cliente y siguiendo sus instrucciones, se aplicará además el régimen correspondiente al encargado del tratamiento, conforme al artículo 28 RGPD."
      }
    ]
  },
  {
    "id": "solicitudes-de-auditor-a-5",
    "number": "5",
    "title": "Solicitudes de auditoría",
    "blocks": [
      {
        "type": "p",
        "text": "Cuando una persona solicite una auditoría a través de MODIRA, pueden tratarse:"
      },
      {
        "type": "bullet",
        "text": "nombre;"
      },
      {
        "type": "bullet",
        "text": "correo electrónico;"
      },
      {
        "type": "bullet",
        "text": "empresa;"
      },
      {
        "type": "bullet",
        "text": "número de empleados;"
      },
      {
        "type": "bullet",
        "text": "descripción del proceso o necesidad planteada;"
      },
      {
        "type": "bullet",
        "text": "información adicional proporcionada voluntariamente."
      },
      {
        "type": "p",
        "text": "Estos datos se tratarán para:"
      },
      {
        "type": "bullet",
        "text": "recibir y gestionar la solicitud;"
      },
      {
        "type": "bullet",
        "text": "analizar la necesidad planteada;"
      },
      {
        "type": "bullet",
        "text": "responder a la persona solicitante;"
      },
      {
        "type": "bullet",
        "text": "mantener las comunicaciones necesarias;"
      },
      {
        "type": "bullet",
        "text": "preparar, cuando corresponda, una eventual relación contractual."
      },
      {
        "type": "p",
        "text": "La base jurídica será principalmente la aplicación de medidas precontractuales a petición del interesado."
      },
      {
        "type": "p",
        "text": "MODIRA dispone además de mecanismos técnicos de protección frente al abuso de este formulario, incluyendo limitación de solicitudes y un identificador técnico derivado de información de conexión."
      },
      {
        "type": "p",
        "text": "La solicitud de una auditoría no implica automáticamente la inscripción en comunicaciones comerciales periódicas."
      }
    ]
  },
  {
    "id": "comunicaciones-por-correo-electr-nico-6",
    "number": "6",
    "title": "Comunicaciones por correo electrónico",
    "blocks": [
      {
        "type": "p",
        "text": "Cuando una persona contacte con MODIRA por correo electrónico, MODIRA podrá tratar:"
      },
      {
        "type": "bullet",
        "text": "dirección de correo;"
      },
      {
        "type": "bullet",
        "text": "nombre y datos de contacto incluidos;"
      },
      {
        "type": "bullet",
        "text": "contenido del mensaje;"
      },
      {
        "type": "bullet",
        "text": "archivos o información que la persona decida enviar."
      },
      {
        "type": "p",
        "text": "La finalidad será:"
      },
      {
        "type": "bullet",
        "text": "responder a la solicitud;"
      },
      {
        "type": "bullet",
        "text": "mantener la comunicación necesaria;"
      },
      {
        "type": "bullet",
        "text": "gestionar una relación contractual o precontractual;"
      },
      {
        "type": "bullet",
        "text": "atender incidencias;"
      },
      {
        "type": "bullet",
        "text": "conservar, cuando sea necesario, evidencias relacionadas con la comunicación."
      },
      {
        "type": "p",
        "text": "MODIRA dispone de una configuración de correo electrónico de producción destinada a las comunicaciones operativas del servicio, incluyendo aquellas relacionadas con autenticación y gestión de cuentas."
      },
      {
        "type": "p",
        "text": "El envío de comunicaciones comerciales estará sujeto a la normativa aplicable y, cuando sea necesario, a un consentimiento específico."
      }
    ]
  },
  {
    "id": "modira-ai-7",
    "number": "7",
    "title": "MODIRA AI",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA dispone de funcionalidades de inteligencia artificial que pueden utilizarse para proporcionar información y asistencia a usuarios, clientes y potenciales clientes."
      },
      {
        "type": "p",
        "text": "MODIRA AI tiene carácter principalmente informativo y asistencial. Entre otras cuestiones, puede utilizarse para:"
      },
      {
        "type": "bullet",
        "text": "informar sobre los servicios disponibles en MODIRA;"
      },
      {
        "type": "bullet",
        "text": "explicar funcionalidades de la plataforma;"
      },
      {
        "type": "bullet",
        "text": "proporcionar ideas de automatización;"
      },
      {
        "type": "bullet",
        "text": "ofrecer recomendaciones generales relacionadas con negocios y procesos empresariales;"
      },
      {
        "type": "bullet",
        "text": "orientar sobre posibles usos de MODIRA;"
      },
      {
        "type": "bullet",
        "text": "responder preguntas sobre la propia web y sus servicios;"
      },
      {
        "type": "bullet",
        "text": "ayudar al usuario a comprender qué puede encontrar o realizar dentro de MODIRA;"
      },
      {
        "type": "bullet",
        "text": "proporcionar información y sugerencias relacionadas con las necesidades planteadas por el usuario."
      },
      {
        "type": "p",
        "text": "No todas las funcionalidades o servicios ofrecidos por MODIRA utilizan inteligencia artificial. La IA puede utilizarse como herramienta de apoyo en determinadas funcionalidades presentes o futuras."
      },
      {
        "type": "subheading",
        "text": "7.1. Datos tratados"
      },
      {
        "type": "p",
        "text": "Cuando una persona utiliza MODIRA AI, puede tratarse:"
      },
      {
        "type": "bullet",
        "text": "contenido de sus mensajes;"
      },
      {
        "type": "bullet",
        "text": "respuestas generadas;"
      },
      {
        "type": "bullet",
        "text": "historial necesario para mantener la conversación;"
      },
      {
        "type": "bullet",
        "text": "identificadores técnicos;"
      },
      {
        "type": "bullet",
        "text": "información asociada a la cuenta cuando el usuario está autenticado;"
      },
      {
        "type": "bullet",
        "text": "información empresarial proporcionada voluntariamente durante la conversación."
      },
      {
        "type": "p",
        "text": "Las conversaciones se almacenan en MODIRA y pueden estar asociadas a una cuenta autenticada o a identificadores técnicos cuando se utiliza la funcionalidad sin autenticación."
      },
      {
        "type": "subheading",
        "text": "7.2. Envío de información a proveedores de IA"
      },
      {
        "type": "p",
        "text": "Los mensajes introducidos en MODIRA AI y el historial necesario para generar una respuesta pueden enviarse a OpenAI para su procesamiento."
      },
      {
        "type": "p",
        "text": "MODIRA no envía deliberadamente a OpenAI como parte del contenido de la petición los identificadores internos user_id, company_id, session_id ni el identificador hash utilizado internamente para determinados controles de abuso."
      },
      {
        "type": "p",
        "text": "No obstante, el propio contenido escrito por el usuario puede contener datos personales. Por ejemplo, si una persona introduce voluntariamente su nombre o información de su empresa dentro de un mensaje, esa información puede formar parte de la petición enviada al proveedor de IA."
      },
      {
        "type": "p",
        "text": "MODIRA recomienda no introducir en la IA datos personales sensibles o información personal de terceros que no resulte necesaria."
      },
      {
        "type": "subheading",
        "text": "7.3. Información empresarial"
      },
      {
        "type": "p",
        "text": "MODIRA puede utilizar la funcionalidad de IA para identificar, cuando el usuario lo haya proporcionado en la conversación, información básica relacionada con su empresa, como:"
      },
      {
        "type": "bullet",
        "text": "nombre de la empresa;"
      },
      {
        "type": "bullet",
        "text": "actividad o sector."
      },
      {
        "type": "p",
        "text": "Esta información puede almacenarse para contextualizar la utilización del servicio."
      },
      {
        "type": "p",
        "text": "La funcionalidad no está diseñada para elaborar perfiles psicológicos, valorar empleados, determinar solvencia, decidir contrataciones, evaluar clientes o adoptar decisiones jurídicas sobre personas."
      },
      {
        "type": "subheading",
        "text": "7.4. Uso interno de las conversaciones"
      },
      {
        "type": "p",
        "text": "Además de permitir la prestación de MODIRA AI, MODIRA puede analizar las conversaciones y consultas realizadas para conocer:"
      },
      {
        "type": "bullet",
        "text": "qué cuestiones plantean los usuarios;"
      },
      {
        "type": "bullet",
        "text": "qué necesidades son recurrentes;"
      },
      {
        "type": "bullet",
        "text": "qué temas interesan a usuarios y potenciales clientes;"
      },
      {
        "type": "bullet",
        "text": "qué dificultades encuentran;"
      },
      {
        "type": "bullet",
        "text": "qué funcionalidades o servicios pueden resultar de utilidad."
      },
      {
        "type": "p",
        "text": "Esta información se utiliza con finalidad informativa, de análisis interno y de mejora de los servicios, contenidos, funcionalidades y experiencia de MODIRA."
      },
      {
        "type": "p",
        "text": "Las conversaciones pueden ser consultadas por personal autorizado de MODIRA cuando resulte necesario para estas finalidades, soporte, supervisión, seguridad o funcionamiento del servicio."
      },
      {
        "type": "p",
        "text": "El acceso estará sujeto a obligaciones de confidencialidad y a los controles internos correspondientes."
      },
      {
        "type": "p",
        "text": "Cuando sea posible y adecuado, MODIRA procurará analizar tendencias y necesidades de forma agregada o evitando utilizar más información identificativa de la necesaria."
      },
      {
        "type": "p",
        "text": "La utilización de esta finalidad basada en interés legítimo quedará documentada internamente mediante la correspondiente ponderación de intereses."
      }
    ]
  },
  {
    "id": "conservaci-n-de-modira-ai-8",
    "number": "8",
    "title": "Conservación de MODIRA AI",
    "blocks": [
      {
        "type": "p",
        "text": "Las conversaciones de MODIRA AI se conservarán durante un máximo de 90 días desde su creación, tras lo cual serán eliminadas conforme al mecanismo de conservación establecido."
      },
      {
        "type": "p",
        "text": "El proveedor de IA puede aplicar sus propios períodos de conservación conforme a sus condiciones aplicables."
      },
      {
        "type": "p",
        "text": "MODIRA aplicará las condiciones y garantías correspondientes al tratamiento realizado mediante proveedores externos de inteligencia artificial."
      }
    ]
  },
  {
    "id": "decisiones-automatizadas-9",
    "number": "9",
    "title": "Decisiones automatizadas",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA puede utilizar sistemas de inteligencia artificial como herramientas asistenciales."
      },
      {
        "type": "p",
        "text": "Sin embargo, las funcionalidades descritas actualmente no adoptan decisiones exclusivamente automatizadas que produzcan efectos jurídicos o afecten significativamente de manera similar a las personas."
      },
      {
        "type": "p",
        "text": "En particular, MODIRA AI no está diseñada para:"
      },
      {
        "type": "bullet",
        "text": "decidir contrataciones;"
      },
      {
        "type": "bullet",
        "text": "decidir empleo;"
      },
      {
        "type": "bullet",
        "text": "conceder o denegar crédito;"
      },
      {
        "type": "bullet",
        "text": "determinar la solvencia de una persona;"
      },
      {
        "type": "bullet",
        "text": "fijar precios individualizados sobre personas mediante decisiones automatizadas;"
      },
      {
        "type": "bullet",
        "text": "expulsar usuarios mediante una decisión automatizada basada en perfiles;"
      },
      {
        "type": "bullet",
        "text": "evaluar empleados;"
      },
      {
        "type": "bullet",
        "text": "evaluar clientes;"
      },
      {
        "type": "bullet",
        "text": "adoptar decisiones jurídicas sobre personas."
      },
      {
        "type": "p",
        "text": "Las respuestas generadas por IA deben ser revisadas por el usuario antes de adoptar decisiones relevantes."
      }
    ]
  },
  {
    "id": "categor-as-especiales-de-datos-10",
    "number": "10",
    "title": "Categorías especiales de datos",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA no necesita categorías especiales de datos personales para prestar sus servicios."
      },
      {
        "type": "p",
        "text": "Entre ellas se encuentran, entre otras:"
      },
      {
        "type": "bullet",
        "text": "datos de salud;"
      },
      {
        "type": "bullet",
        "text": "origen racial o étnico;"
      },
      {
        "type": "bullet",
        "text": "opiniones políticas;"
      },
      {
        "type": "bullet",
        "text": "creencias religiosas o filosóficas;"
      },
      {
        "type": "bullet",
        "text": "afiliación sindical;"
      },
      {
        "type": "bullet",
        "text": "datos genéticos;"
      },
      {
        "type": "bullet",
        "text": "determinados datos biométricos;"
      },
      {
        "type": "bullet",
        "text": "vida sexual u orientación sexual."
      },
      {
        "type": "p",
        "text": "No obstante, determinadas funcionalidades contienen campos de texto libre y un usuario podría introducir voluntariamente este tipo de información."
      },
      {
        "type": "p",
        "text": "Por ello, se recomienda no introducir categorías especiales de datos personales cuando no sean necesarias, especialmente en MODIRA AI, auditorías, proyectos, tickets y campos descriptivos."
      }
    ]
  },
  {
    "id": "pagos-mediante-stripe-11",
    "number": "11",
    "title": "Pagos mediante Stripe",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA utiliza Stripe como proveedor de servicios de pago."
      },
      {
        "type": "p",
        "text": "El flujo de pago se inicia desde MODIRA y se procesa mediante Stripe Checkout."
      },
      {
        "type": "p",
        "text": "MODIRA no recibe ni almacena directamente los datos completos de la tarjeta utilizados para efectuar el pago."
      },
      {
        "type": "p",
        "text": "Sí trata información asociada a la operación económica, incluyendo, según corresponda:"
      },
      {
        "type": "bullet",
        "text": "identificador de factura;"
      },
      {
        "type": "bullet",
        "text": "identificador de usuario;"
      },
      {
        "type": "bullet",
        "text": "identificador de empresa;"
      },
      {
        "type": "bullet",
        "text": "dirección de correo electrónico;"
      },
      {
        "type": "bullet",
        "text": "importe;"
      },
      {
        "type": "bullet",
        "text": "moneda;"
      },
      {
        "type": "bullet",
        "text": "descripción o concepto;"
      },
      {
        "type": "bullet",
        "text": "identificador de Checkout Session;"
      },
      {
        "type": "bullet",
        "text": "identificador de PaymentIntent;"
      },
      {
        "type": "bullet",
        "text": "estado del pago;"
      },
      {
        "type": "bullet",
        "text": "fecha de pago."
      },
      {
        "type": "p",
        "text": "Determinada información de la factura puede comunicarse a Stripe para permitir la correcta creación y gestión de la operación."
      },
      {
        "type": "p",
        "text": "MODIRA también conserva determinados eventos técnicos procedentes de Stripe para garantizar la trazabilidad e integridad del procesamiento y evitar duplicidades."
      },
      {
        "type": "p",
        "text": "Stripe puede actuar bajo distintos roles jurídicos dependiendo del tratamiento concreto. Por ello, MODIRA no lo calificará genéricamente como mero encargado para todos los tratamientos."
      }
    ]
  },
  {
    "id": "facturaci-n-y-conservaci-n-de-documentaci-n-econ-mica-12",
    "number": "12",
    "title": "Facturación y conservación de documentación económica",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA tratará datos relacionados con:"
      },
      {
        "type": "bullet",
        "text": "presupuestos;"
      },
      {
        "type": "bullet",
        "text": "facturas;"
      },
      {
        "type": "bullet",
        "text": "impuestos;"
      },
      {
        "type": "bullet",
        "text": "operaciones económicas;"
      },
      {
        "type": "bullet",
        "text": "pagos;"
      },
      {
        "type": "bullet",
        "text": "documentación justificativa."
      },
      {
        "type": "p",
        "text": "La finalidad será:"
      },
      {
        "type": "bullet",
        "text": "gestionar la relación contractual;"
      },
      {
        "type": "bullet",
        "text": "emitir y gestionar facturas;"
      },
      {
        "type": "bullet",
        "text": "registrar pagos;"
      },
      {
        "type": "bullet",
        "text": "cumplir obligaciones fiscales, contables y mercantiles;"
      },
      {
        "type": "bullet",
        "text": "ejercer o defender derechos y reclamaciones."
      },
      {
        "type": "p",
        "text": "La base jurídica podrá ser la ejecución del contrato y el cumplimiento de obligaciones legales."
      },
      {
        "type": "p",
        "text": "La documentación relacionada con facturación y operaciones económicas se conservará durante un período de 6 años, sin perjuicio de aquellos supuestos en los que una obligación legal, procedimiento, reclamación o circunstancia justificativa requiera una conservación diferente."
      },
      {
        "type": "p",
        "text": "La supresión de una cuenta no implica necesariamente la eliminación de toda la documentación económica vinculada."
      }
    ]
  },
  {
    "id": "soporte-y-actividad-13",
    "number": "13",
    "title": "Soporte y actividad",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA puede tratar datos relacionados con:"
      },
      {
        "type": "bullet",
        "text": "tickets;"
      },
      {
        "type": "bullet",
        "text": "incidencias;"
      },
      {
        "type": "bullet",
        "text": "solicitudes;"
      },
      {
        "type": "bullet",
        "text": "comunicaciones;"
      },
      {
        "type": "bullet",
        "text": "acciones realizadas en la plataforma;"
      },
      {
        "type": "bullet",
        "text": "información técnica necesaria para resolver problemas."
      },
      {
        "type": "p",
        "text": "Los registros de actividad pueden incluir usuario, empresa, acción realizada, recurso afectado, descripción, metadatos y fecha."
      },
      {
        "type": "p",
        "text": "Su finalidad será:"
      },
      {
        "type": "bullet",
        "text": "prestar soporte;"
      },
      {
        "type": "bullet",
        "text": "mantener la trazabilidad;"
      },
      {
        "type": "bullet",
        "text": "investigar incidencias;"
      },
      {
        "type": "bullet",
        "text": "garantizar la seguridad;"
      },
      {
        "type": "bullet",
        "text": "prevenir usos indebidos;"
      },
      {
        "type": "bullet",
        "text": "cumplir obligaciones legales."
      },
      {
        "type": "p",
        "text": "Como criterio de conservación, los registros de actividad se conservarán durante 12 meses, salvo que resulte necesario conservar determinados registros durante más tiempo por una incidencia, fraude, reclamación, investigación o obligación legal."
      }
    ]
  },
  {
    "id": "seguridad-y-prevenci-n-del-abuso-14",
    "number": "14",
    "title": "Seguridad y prevención del abuso",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA aplica medidas técnicas y organizativas destinadas a proteger los datos personales y los sistemas."
      },
      {
        "type": "p",
        "text": "Entre ellas se encuentran, según el sistema o funcionalidad:"
      },
      {
        "type": "bullet",
        "text": "autenticación;"
      },
      {
        "type": "bullet",
        "text": "control de acceso;"
      },
      {
        "type": "bullet",
        "text": "separación de información por usuario y empresa;"
      },
      {
        "type": "bullet",
        "text": "políticas RLS;"
      },
      {
        "type": "bullet",
        "text": "control de roles;"
      },
      {
        "type": "bullet",
        "text": "revocación de sesiones;"
      },
      {
        "type": "bullet",
        "text": "protección frente a abuso;"
      },
      {
        "type": "bullet",
        "text": "limitación de solicitudes;"
      },
      {
        "type": "bullet",
        "text": "controles de tamaño y contenido;"
      },
      {
        "type": "bullet",
        "text": "almacenamiento privado de documentos;"
      },
      {
        "type": "bullet",
        "text": "cifrado en tránsito;"
      },
      {
        "type": "bullet",
        "text": "controles específicos sobre pagos;"
      },
      {
        "type": "bullet",
        "text": "copias de seguridad;"
      },
      {
        "type": "bullet",
        "text": "monitorización y registros de seguridad."
      },
      {
        "type": "p",
        "text": "MODIRA aplica mecanismos de protección frente a accesos no autorizados, uso indebido, abuso automatizado y otros riesgos relacionados con la disponibilidad, integridad y confidencialidad del servicio."
      }
    ]
  },
  {
    "id": "informaci-n-t-cnica-e-ip-15",
    "number": "15",
    "title": "Información técnica e IP",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA puede tratar información técnica asociada a la conexión, incluida la dirección IP observada por la infraestructura utilizada para prestar y proteger el servicio."
      },
      {
        "type": "p",
        "text": "En determinados mecanismos de prevención del abuso, la dirección IP se transforma mediante una función criptográfica y se utiliza como identificador técnico para aplicar límites de uso y prevenir abusos."
      },
      {
        "type": "p",
        "text": "Este identificador no se considera un dato completamente anónimo y se trata como información técnica seudonimizada."
      },
      {
        "type": "p",
        "text": "MODIRA aplica mecanismos de limitación de solicitudes y protección frente al uso abusivo, incluyendo controles asociados a usuarios, sesiones, identidades técnicas y determinados límites globales."
      },
      {
        "type": "p",
        "text": "Los valores técnicos concretos de estos límites pueden modificarse por razones de seguridad y no forman parte necesariamente de esta Política."
      }
    ]
  },
  {
    "id": "copias-de-seguridad-16",
    "number": "16",
    "title": "Copias de seguridad",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA realiza copias de seguridad destinadas a garantizar la continuidad del servicio y la recuperación ante incidentes."
      },
      {
        "type": "p",
        "text": "Actualmente existe un sistema de copia diaria de determinados datos de la base de datos de MODIRA, programado aproximadamente a las 22:00 horas (España)."
      },
      {
        "type": "p",
        "text": "Si el equipo encargado de ejecutar la copia no está disponible en el momento programado, la operación se ejecuta cuando vuelve a estar disponible."
      },
      {
        "type": "p",
        "text": "Las copias se almacenan de forma cifrada y se utilizan medidas destinadas a evitar la conservación de archivos de datos en claro en el almacenamiento externo."
      },
      {
        "type": "p",
        "text": "Las copias de seguridad podrán contener datos personales necesarios para la recuperación del sistema."
      },
      {
        "type": "p",
        "text": "La eliminación de un dato del sistema operativo no implica necesariamente su desaparición inmediata de todas las copias de seguridad."
      },
      {
        "type": "p",
        "text": "Los datos eliminados podrán permanecer temporalmente en copias de seguridad hasta su sobrescritura o eliminación conforme al ciclo de conservación establecido para dichas copias, sin utilizarse para finalidades operativas durante ese período."
      },
      {
        "type": "p",
        "text": "MODIRA aplica un ciclo de conservación limitado de las copias de seguridad de hasta 30 días, salvo que exista una necesidad técnica o de seguridad debidamente justificada."
      }
    ]
  },
  {
    "id": "proveedores-tecnol-gicos-17",
    "number": "17",
    "title": "Proveedores tecnológicos",
    "blocks": [
      {
        "type": "p",
        "text": "Para prestar sus servicios, MODIRA utiliza distintos proveedores tecnológicos."
      },
      {
        "type": "p",
        "text": "Entre ellos pueden encontrarse:"
      },
      {
        "type": "label",
        "text": "Supabase"
      },
      {
        "type": "p",
        "text": "Utilizado para:"
      },
      {
        "type": "bullet",
        "text": "base de datos;"
      },
      {
        "type": "bullet",
        "text": "autenticación;"
      },
      {
        "type": "bullet",
        "text": "almacenamiento;"
      },
      {
        "type": "bullet",
        "text": "funciones backend."
      },
      {
        "type": "p",
        "text": "El proyecto principal de MODIRA se encuentra alojado en la región de Frankfurt, Alemania."
      },
      {
        "type": "label",
        "text": "Vercel"
      },
      {
        "type": "p",
        "text": "Utilizado para el alojamiento y despliegue del frontend."
      },
      {
        "type": "label",
        "text": "Hostinger"
      },
      {
        "type": "p",
        "text": "Utilizado para la gestión relacionada con el dominio y DNS de MODIRA."
      },
      {
        "type": "label",
        "text": "Cloudflare Turnstile"
      },
      {
        "type": "p",
        "text": "Utilizado como mecanismo de protección frente a bots y abuso."
      },
      {
        "type": "label",
        "text": "Google Analytics 4"
      },
      {
        "type": "p",
        "text": "Utilizado para analítica únicamente cuando se ha obtenido el consentimiento correspondiente."
      },
      {
        "type": "label",
        "text": "Stripe"
      },
      {
        "type": "p",
        "text": "Utilizado para la gestión de pagos."
      },
      {
        "type": "label",
        "text": "OpenAI"
      },
      {
        "type": "p",
        "text": "Utilizado para determinadas funcionalidades de inteligencia artificial."
      },
      {
        "type": "label",
        "text": "Google Drive"
      },
      {
        "type": "p",
        "text": "MODIRA utiliza Google Drive empresarial para el almacenamiento externo de determinadas copias de seguridad y archivos necesarios para garantizar la recuperación y continuidad del servicio."
      },
      {
        "type": "p",
        "text": "Las copias de seguridad almacenadas externamente se gestionan aplicando las medidas de seguridad correspondientes."
      },
      {
        "type": "label",
        "text": "Proveedores de correo electrónico"
      },
      {
        "type": "p",
        "text": "MODIRA utiliza servicios de correo electrónico para comunicaciones operativas, autenticación y gestión de cuentas."
      },
      {
        "type": "p",
        "text": "MODIRA dispone de una configuración SMTP de producción destinada a estas comunicaciones."
      },
      {
        "type": "p",
        "text": "El papel jurídico de cada proveedor dependerá del tratamiento concreto que realice."
      }
    ]
  },
  {
    "id": "modira-como-responsable-y-como-encargado-18",
    "number": "18",
    "title": "MODIRA como responsable y como encargado",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA actúa como responsable del tratamiento respecto de los tratamientos en los que determina los fines y medios, incluyendo, entre otros:"
      },
      {
        "type": "bullet",
        "text": "gestión de sus propias cuentas;"
      },
      {
        "type": "bullet",
        "text": "gestión de usuarios;"
      },
      {
        "type": "bullet",
        "text": "prestación de sus servicios;"
      },
      {
        "type": "bullet",
        "text": "facturación propia;"
      },
      {
        "type": "bullet",
        "text": "pagos;"
      },
      {
        "type": "bullet",
        "text": "solicitudes de auditoría;"
      },
      {
        "type": "bullet",
        "text": "soporte;"
      },
      {
        "type": "bullet",
        "text": "seguridad;"
      },
      {
        "type": "bullet",
        "text": "determinadas funcionalidades de IA;"
      },
      {
        "type": "bullet",
        "text": "analítica y cookies cuando corresponda;"
      },
      {
        "type": "bullet",
        "text": "gestión de derechos."
      },
      {
        "type": "p",
        "text": "Cuando una empresa cliente utilice MODIRA para tratar datos personales de terceros siguiendo sus instrucciones, MODIRA podrá actuar como encargado del tratamiento."
      },
      {
        "type": "p",
        "text": "En ese supuesto:"
      },
      {
        "type": "bullet",
        "text": "la empresa cliente determinará los fines del tratamiento;"
      },
      {
        "type": "bullet",
        "text": "MODIRA tratará los datos conforme a sus instrucciones;"
      },
      {
        "type": "bullet",
        "text": "se aplicarán las obligaciones del artículo 28 RGPD;"
      },
      {
        "type": "bullet",
        "text": "podrán utilizarse subencargados cuando corresponda;"
      },
      {
        "type": "bullet",
        "text": "se regularán las condiciones mediante el correspondiente Acuerdo de Encargo del Tratamiento (DPA)."
      }
    ]
  },
  {
    "id": "subencargados-19",
    "number": "19",
    "title": "Subencargados",
    "blocks": [
      {
        "type": "p",
        "text": "Cuando MODIRA actúe como encargado, podrá utilizar proveedores tecnológicos que actúen como subencargados cuando resulte necesario para prestar el servicio."
      },
      {
        "type": "p",
        "text": "MODIRA establecerá contractualmente las condiciones aplicables y gestionará la incorporación o sustitución de subencargados conforme al RGPD y al DPA correspondiente."
      },
      {
        "type": "p",
        "text": "No todos los proveedores de MODIRA tienen necesariamente la condición de subencargado en todos sus tratamientos. Algunos pueden actuar como responsables independientes para determinados fines propios."
      },
      {
        "type": "p",
        "text": "Esto resulta especialmente relevante en proveedores como Stripe."
      }
    ]
  },
  {
    "id": "transferencias-internacionales-20",
    "number": "20",
    "title": "Transferencias internacionales",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA utiliza proveedores tecnológicos que pueden realizar tratamientos dentro y fuera del Espacio Económico Europeo."
      },
      {
        "type": "p",
        "text": "El hecho de que la infraestructura principal de MODIRA en Supabase se encuentre en Frankfurt (Alemania) no significa que todos los tratamientos realizados por todos los proveedores permanezcan necesariamente dentro del EEE."
      },
      {
        "type": "p",
        "text": "Cuando exista una transferencia internacional de datos personales, MODIRA aplicará los mecanismos previstos por el RGPD, como:"
      },
      {
        "type": "bullet",
        "text": "decisiones de adecuación;"
      },
      {
        "type": "bullet",
        "text": "cláusulas contractuales tipo;"
      },
      {
        "type": "bullet",
        "text": "otras garantías adecuadas;"
      },
      {
        "type": "bullet",
        "text": "excepciones legalmente aplicables cuando proceda."
      },
      {
        "type": "p",
        "text": "El artículo 44 RGPD establece que las transferencias a terceros países deben cumplir las condiciones establecidas en el capítulo V del Reglamento."
      },
      {
        "type": "p",
        "text": "MODIRA facilitará información adicional sobre los mecanismos de transferencia cuando sea necesario."
      }
    ]
  },
  {
    "id": "google-analytics-y-cookies-21",
    "number": "21",
    "title": "Google Analytics y cookies",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA utiliza Google Analytics 4 únicamente cuando el usuario ha prestado el consentimiento correspondiente."
      },
      {
        "type": "p",
        "text": "Las tecnologías no necesarias permanecen desactivadas hasta que se obtiene dicho consentimiento."
      },
      {
        "type": "p",
        "text": "El usuario puede:"
      },
      {
        "type": "bullet",
        "text": "aceptar;"
      },
      {
        "type": "bullet",
        "text": "rechazar;"
      },
      {
        "type": "bullet",
        "text": "configurar sus preferencias."
      },
      {
        "type": "p",
        "text": "La decisión sobre analítica se conserva para poder acreditar y respetar la elección realizada."
      },
      {
        "type": "p",
        "text": "MODIRA dispone además de un registro persistente de las decisiones de consentimiento que contiene la elección correspondiente, versión de la política, fecha/hora y un identificador técnico, sin almacenar en dicho registro IP, correo electrónico, nombre, user-agent ni fingerprint."
      },
      {
        "type": "p",
        "text": "La Política de Cookies desarrolla específicamente estas tecnologías y los mecanismos para modificar o retirar el consentimiento."
      },
      {
        "type": "p",
        "text": "MODIRA no utiliza actualmente Google Ads, Meta Ads ni sistemas de remarketing como parte de este tratamiento. Si se incorporasen, se actualizarían las políticas y mecanismos de consentimiento correspondientes."
      }
    ]
  },
  {
    "id": "conservaci-n-de-los-datos-22",
    "number": "22",
    "title": "Conservación de los datos",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA conservará los datos personales durante el tiempo necesario para cumplir las finalidades para las que fueron obtenidos."
      },
      {
        "type": "p",
        "text": "Como criterios generales:"
      },
      {
        "type": "bullet",
        "text": "cuentas: mientras permanezcan activas;"
      },
      {
        "type": "bullet",
        "text": "cuentas cerradas: hasta 30 días para las operaciones de eliminación;"
      },
      {
        "type": "bullet",
        "text": "perfiles: mientras la cuenta esté activa y, cuando proceda, hasta 30 días adicionales;"
      },
      {
        "type": "bullet",
        "text": "proyectos y documentos: mientras resulten necesarios para prestar el servicio o atender obligaciones;"
      },
      {
        "type": "bullet",
        "text": "auditorías: 12 meses;"
      },
      {
        "type": "bullet",
        "text": "soporte: 12 meses desde el cierre;"
      },
      {
        "type": "bullet",
        "text": "presupuestos no aceptados: 12 meses;"
      },
      {
        "type": "bullet",
        "text": "presupuestos aceptados: 6 años como criterio interno;"
      },
      {
        "type": "bullet",
        "text": "MODIRA AI: máximo 90 días;"
      },
      {
        "type": "bullet",
        "text": "facturación y documentación económica: 6 años;"
      },
      {
        "type": "bullet",
        "text": "activity logs: 12 meses;"
      },
      {
        "type": "bullet",
        "text": "registros de seguridad: 12 meses, salvo incidentes o reclamaciones;"
      },
      {
        "type": "bullet",
        "text": "mecanismos antifraude y rate limiting: 90 días;"
      },
      {
        "type": "bullet",
        "text": "consentimientos: mientras sean necesarios para acreditar el consentimiento;"
      },
      {
        "type": "bullet",
        "text": "datos económicos y documentación sometida a obligaciones legales: durante los plazos legalmente aplicables."
      },
      {
        "type": "p",
        "text": "Estos períodos podrán ampliarse cuando sea necesario para cumplir obligaciones legales o formular, ejercer o defender reclamaciones."
      }
    ]
  },
  {
    "id": "supresi-n-de-cuentas-y-datos-23",
    "number": "23",
    "title": "Supresión de cuentas y datos",
    "blocks": [
      {
        "type": "p",
        "text": "Cuando un usuario solicite la eliminación de su cuenta, MODIRA comprobará previamente si existen:"
      },
      {
        "type": "bullet",
        "text": "obligaciones legales de conservación;"
      },
      {
        "type": "bullet",
        "text": "facturas;"
      },
      {
        "type": "bullet",
        "text": "documentación económica;"
      },
      {
        "type": "bullet",
        "text": "contratos;"
      },
      {
        "type": "bullet",
        "text": "reclamaciones;"
      },
      {
        "type": "bullet",
        "text": "evidencias necesarias;"
      },
      {
        "type": "bullet",
        "text": "otros datos cuya conservación esté legalmente justificada."
      },
      {
        "type": "p",
        "text": "Los datos que no deban conservarse serán eliminados de los sistemas operativos cuando corresponda."
      },
      {
        "type": "p",
        "text": "La eliminación de la cuenta podrá implicar:"
      },
      {
        "type": "bullet",
        "text": "eliminación del perfil;"
      },
      {
        "type": "bullet",
        "text": "eliminación del acceso;"
      },
      {
        "type": "bullet",
        "text": "revocación de sesiones;"
      },
      {
        "type": "bullet",
        "text": "eliminación de datos operativos;"
      },
      {
        "type": "bullet",
        "text": "eliminación de proyectos y conversaciones que corresponda eliminar;"
      },
      {
        "type": "bullet",
        "text": "eliminación de documentación cuando proceda."
      },
      {
        "type": "p",
        "text": "Los datos sujetos a obligaciones legales o necesarios para formular, ejercer o defender reclamaciones podrán conservarse durante el período correspondiente."
      },
      {
        "type": "p",
        "text": "Los datos pueden permanecer temporalmente en copias de seguridad conforme al ciclo de conservación de estas."
      }
    ]
  },
  {
    "id": "ejercicio-de-derechos-24",
    "number": "24",
    "title": "Ejercicio de derechos",
    "blocks": [
      {
        "type": "p",
        "text": "Las personas interesadas pueden ejercer los derechos reconocidos por la normativa aplicable, incluyendo:"
      },
      {
        "type": "bullet",
        "text": "acceso;"
      },
      {
        "type": "bullet",
        "text": "rectificación;"
      },
      {
        "type": "bullet",
        "text": "supresión;"
      },
      {
        "type": "bullet",
        "text": "limitación del tratamiento;"
      },
      {
        "type": "bullet",
        "text": "oposición;"
      },
      {
        "type": "bullet",
        "text": "portabilidad;"
      },
      {
        "type": "bullet",
        "text": "retirada del consentimiento, cuando el tratamiento se base en consentimiento."
      },
      {
        "type": "p",
        "text": "Cuando el tratamiento se base en interés legítimo, la persona podrá ejercer también su derecho de oposición conforme a las condiciones del RGPD."
      },
      {
        "type": "p",
        "text": "Las solicitudes podrán dirigirse a:"
      },
      {
        "type": "p",
        "text": "info@modira.es"
      },
      {
        "type": "p",
        "text": "MODIRA podrá solicitar información adicional para verificar razonablemente la identidad del solicitante cuando resulte necesario."
      },
      {
        "type": "p",
        "text": "El plazo general de respuesta será de un mes, pudiendo ampliarse por otros dos meses cuando la complejidad o el número de solicitudes lo justifique, informando al interesado de dicha ampliación dentro del primer mes."
      }
    ]
  },
  {
    "id": "derechos-respecto-de-datos-tratados-por-cuenta-de-empresas-25",
    "number": "25",
    "title": "Derechos respecto de datos tratados por cuenta de empresas",
    "blocks": [
      {
        "type": "p",
        "text": "Cuando MODIRA actúe como encargado del tratamiento y una solicitud de derechos afecte a datos tratados por cuenta de una empresa cliente, MODIRA gestionará la solicitud conforme a las instrucciones del responsable del tratamiento correspondiente y al DPA aplicable."
      },
      {
        "type": "p",
        "text": "MODIRA no decidirá unilateralmente sobre datos respecto de los cuales actúe únicamente como encargado, salvo cuando exista una obligación legal propia que requiera otra actuación."
      }
    ]
  },
  {
    "id": "confidencialidad-y-acceso-interno-26",
    "number": "26",
    "title": "Confidencialidad y acceso interno",
    "blocks": [
      {
        "type": "p",
        "text": "El acceso interno a datos personales estará limitado a las personas autorizadas que necesiten acceder a ellos para desarrollar sus funciones."
      },
      {
        "type": "p",
        "text": "Los trabajadores o colaboradores autorizados dispondrán de cuentas individuales y deberán mantener la confidencialidad de las credenciales y de la información a la que tengan acceso."
      },
      {
        "type": "p",
        "text": "Cuando finalice su relación con MODIRA, su acceso será bloqueado."
      }
    ]
  },
  {
    "id": "incidentes-de-seguridad-y-brechas-27",
    "number": "27",
    "title": "Incidentes de seguridad y brechas",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA dispone de medidas destinadas a prevenir, detectar y responder ante incidentes de seguridad."
      },
      {
        "type": "p",
        "text": "En caso de producirse una brecha de seguridad que afecte a datos personales, MODIRA evaluará:"
      },
      {
        "type": "numbered",
        "text": "la naturaleza del incidente;"
      },
      {
        "type": "numbered",
        "text": "los datos afectados;"
      },
      {
        "type": "numbered",
        "text": "las personas afectadas;"
      },
      {
        "type": "numbered",
        "text": "los riesgos para sus derechos y libertades;"
      },
      {
        "type": "numbered",
        "text": "las medidas de contención;"
      },
      {
        "type": "numbered",
        "text": "la necesidad de notificación a la autoridad de control;"
      },
      {
        "type": "numbered",
        "text": "la necesidad de comunicación a los afectados;"
      },
      {
        "type": "numbered",
        "text": "las medidas correctoras;"
      },
      {
        "type": "numbered",
        "text": "la documentación del incidente."
      },
      {
        "type": "p",
        "text": "La existencia de un incidente no implica automáticamente que deba comunicarse a todas las personas afectadas; la actuación dependerá de la evaluación del riesgo exigida por la normativa."
      }
    ]
  },
  {
    "id": "menores-de-edad-28",
    "number": "28",
    "title": "Menores de edad",
    "blocks": [
      {
        "type": "p",
        "text": "El contenido público de MODIRA puede ser consultado por personas de cualquier edad."
      },
      {
        "type": "p",
        "text": "No obstante, los servicios contractuales de MODIRA están dirigidos a personas con capacidad legal para contratar y, en particular, a mayores de edad y empresas o profesionales."
      },
      {
        "type": "p",
        "text": "MODIRA no dirige sus servicios a menores como público objetivo ni solicita deliberadamente categorías especiales de datos de menores."
      }
    ]
  },
  {
    "id": "informaci-n-relativa-a-proveedores-y-cambios-tecnol-gicos-29",
    "number": "29",
    "title": "Información relativa a proveedores y cambios tecnológicos",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA podrá actualizar o sustituir proveedores tecnológicos cuando sea necesario para prestar, proteger o mejorar sus servicios."
      },
      {
        "type": "p",
        "text": "Cuando dichos cambios impliquen nuevos tratamientos, nuevos destinatarios o nuevas transferencias internacionales que requieran información específica, MODIRA actualizará esta Política y, cuando corresponda, sus mecanismos de información y consentimiento."
      }
    ]
  },
  {
    "id": "actualizaciones-de-esta-pol-tica-30",
    "number": "30",
    "title": "Actualizaciones de esta Política",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA podrá actualizar esta Política para reflejar:"
      },
      {
        "type": "bullet",
        "text": "cambios legislativos;"
      },
      {
        "type": "bullet",
        "text": "cambios en los tratamientos;"
      },
      {
        "type": "bullet",
        "text": "incorporación o sustitución de proveedores;"
      },
      {
        "type": "bullet",
        "text": "nuevas funcionalidades;"
      },
      {
        "type": "bullet",
        "text": "modificaciones de seguridad;"
      },
      {
        "type": "bullet",
        "text": "cambios en los servicios;"
      },
      {
        "type": "bullet",
        "text": "cambios en las tecnologías utilizadas."
      },
      {
        "type": "p",
        "text": "La versión vigente estará disponible en el sitio web de MODIRA."
      },
      {
        "type": "p",
        "text": "Cuando una modificación requiera una nueva información o consentimiento, MODIRA adoptará las medidas correspondientes antes de aplicar el nuevo tratamiento."
      }
    ]
  },
  {
    "id": "reclamaciones-ante-la-autoridad-de-control-31",
    "number": "31",
    "title": "Reclamaciones ante la autoridad de control",
    "blocks": [
      {
        "type": "p",
        "text": "Si una persona considera que el tratamiento de sus datos personales no cumple la normativa aplicable, puede presentar una reclamación ante la autoridad de control competente."
      },
      {
        "type": "p",
        "text": "En España:"
      },
      {
        "type": "p",
        "text": "Agencia Española de Protección de Datos (AEPD)"
      },
      {
        "type": "p",
        "text": "MODIRA recomienda, no obstante, contactar previamente con MODIRA para intentar resolver cualquier cuestión relacionada con el tratamiento de datos."
      }
    ]
  },
  {
    "id": "base-jur-dica-resumida-de-los-principales-tratamientos-32",
    "number": "32",
    "title": "Base jurídica resumida de los principales tratamientos",
    "blocks": [],
    "table": [
      [
        "Registro y cuenta",
        "Contrato / medidas precontractuales"
      ],
      [
        "Autenticación",
        "Contrato"
      ],
      [
        "Prestación del servicio",
        "Contrato"
      ],
      [
        "Proyectos",
        "Contrato"
      ],
      [
        "Presupuestos",
        "Medidas precontractuales / contrato"
      ],
      [
        "Facturación",
        "Contrato + obligación legal"
      ],
      [
        "Pagos",
        "Contrato + obligaciones legales aplicables"
      ],
      [
        "Auditoría solicitada",
        "Medidas precontractuales"
      ],
      [
        "Soporte",
        "Contrato / interés legítimo según contexto"
      ],
      [
        "Seguridad",
        "Interés legítimo / obligación legal cuando proceda"
      ],
      [
        "Prevención de abuso",
        "Interés legítimo"
      ],
      [
        "Registros de actividad",
        "Interés legítimo / seguridad"
      ],
      [
        "MODIRA AI — prestación informativa y asistencial",
        "Base correspondiente a la funcionalidad/relación"
      ],
      [
        "MODIRA AI — análisis interno",
        "Interés legítimo, sujeto a ponderación"
      ],
      [
        "Cookies analíticas / GA4",
        "Consentimiento"
      ],
      [
        "Gestión de derechos",
        "Obligación legal"
      ],
      [
        "Conservación legal",
        "Obligación legal"
      ],
      [
        "Comunicaciones comerciales",
        "Consentimiento o base legal aplicable según el supuesto"
      ]
    ],
    "table_header": [
      "Tratamiento",
      "Base jurídica principal"
    ]
  },
  {
    "id": "versi-n-y-entrada-en-vigor-33",
    "number": "33",
    "title": "Versión y entrada en vigor",
    "blocks": [
      {
        "type": "info"
      }
    ],
    "info": [
      [
        "Versión",
        "1.0"
      ],
      [
        "Fecha de elaboración",
        "14 de septiembre de 2026"
      ],
      [
        "Fecha de entrada en vigor",
        "14 de septiembre de 2026"
      ]
    ]
    
  },
  {
    "id": "responsable-del-tratamiento-34",
    "number": "34",
    "title": "Responsable del tratamiento",
    "blocks": [
      {
        "type": "p",
        "text": "El responsable del tratamiento de los datos personales tratados a través de MODIRA es:"
      },
      {
        "type": "info"
      },
      

      {
        "type": "p",
        "text": "MODIRA tratará los datos personales de conformidad con el Reglamento (UE) 2016/679, General de Protección de Datos («RGPD»), la Ley Orgánica 3/2018, de Protección de Datos Personales y garantía de los derechos digitales («LOPDGDD») y demás normativa aplicable."
      }
    ],
    "info": [
      [
        "Sitio web",
        "https://modira.es"
      ],
      [
        "Correo electrónico de contacto",
        "info@modira.es"
      ],
      [
        "Titular",
        "Adrián Modino Merino"
      ],
      [
        "NIF",
        "06641212P"
      ],
      [
        "Domicilio",
        "Calle Lisboa 25, 28670, Villaviciosa de Odón, Madrid, España"
      ],
      
    ],
    "dpd": "[DATOS DEL DPD, SI PROCEDE]"
  }
];

export default function PrivacyPolicy() {
  const [isScrolled, setIsScrolled] = useState(false);

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
      className={`min-h-screen bg-[#F8FAFC] privacy-page ${
        isScrolled
          ? "privacy-scrolled"
          : "privacy-top"
      }`}
    >
      {/* ========================================================
          HEADER
          ======================================================== */}

      <div
        className={`privacy-header-wrapper ${
          isScrolled
            ? "privacy-header-scrolled"
            : "privacy-header-transparent"
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
                    Política de Privacidad
                  </h1>

                  <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
                    Información sobre cómo MODIRA trata, protege, conserva y
                    gestiona los datos personales en relación con su sitio web,
                    servicios, cuentas y funcionalidades.
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

                  {/* Intro exacta del documento */}

                  <div className="pb-10 mb-10 border-b border-gray-100">
                    <p className="text-sm font-semibold text-[#1E3A8A] mb-2">
                      POLÍTICA DE PRIVACIDAD DE MODIRA
                    </p>
                    <p className="text-sm leading-7 text-gray-500">
                      Última actualización: 14/09/2026
                    </p>
                  </div>

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
                          {section.blocks.map((block, index) => {
                            if (block.type === "info") {
                              return (
                                <div
                                  key={index}
                                  className="rounded-xl border border-gray-100 bg-[#F8FAFC] overflow-hidden"
                                >
                                  {section.info?.map(([label, value], infoIndex) => (
                                    <div
                                      key={label}
                                      className={`grid sm:grid-cols-[190px_1fr] gap-2 sm:gap-6 px-5 py-4 ${
                                        infoIndex !== section.info!.length - 1
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
                                  ))}
                                </div>
                              );
                            }

                            if (block.type === "info2") {
                              return (
                                <div
                                  key={index}
                                  className="rounded-xl border border-gray-100 bg-[#F8FAFC] px-5 py-4"
                                >
                                  <span className="text-sm text-gray-500 break-words">
                                    {section.dpd}
                                  </span>
                                </div>
                              );
                            }

                            if (block.type === "subheading") {
                              return (
                                <div
                                  key={index}
                                  className="pt-5 mt-5 border-t border-gray-100"
                                >
                                  <h3 className="text-base md:text-lg font-semibold text-[#1E3A8A] leading-7">
                                    {block.text}
                                  </h3>
                                </div>
                              );
                            }

                            if (block.type === "label") {
                              return (
                                <h3
                                  key={index}
                                  className="text-base md:text-lg font-semibold text-gray-800 pt-2"
                                >
                                  {block.text}
                                </h3>
                              );
                            }

                            if (block.type === "bullet") {
                              return (
                                <div
                                  key={index}
                                  className="flex items-start gap-3 text-[15px] md:text-base text-gray-600 leading-7"
                                >
                                  <span className="mt-[11px] w-1.5 h-1.5 rounded-full bg-[#1E3A8A] flex-shrink-0" />
                                  <span>{block.text}</span>
                                </div>
                              );
                            }

                            if (block.type === "numbered") {
                              const numberedBlocks = section.blocks.filter(
                                (candidate) => candidate.type === "numbered"
                              );
                              const number =
                                numberedBlocks.findIndex(
                                  (candidate) => candidate === block
                                ) + 1;

                              return (
                                <div
                                  key={index}
                                  className="flex items-start gap-3 text-[15px] md:text-base text-gray-600 leading-7"
                                >
                                  <span className="font-medium text-gray-500 min-w-5">
                                    {number}.
                                  </span>
                                  <span>{block.text}</span>
                                </div>
                              );
                            }

                            return (
                              <p
                                key={index}
                                className="text-[15px] md:text-base text-gray-600 leading-7"
                              >
                                {block.text}
                              </p>
                            );
                          })}

                          {/* Tabla de bases jurídicas — sección 33 */}

                          {section.table && (
                            <div className="overflow-x-auto rounded-xl border border-gray-100">
                              <table className="w-full text-left border-collapse">
                                <thead>
                                  <tr className="bg-[#F8FAFC] border-b border-gray-100">
                                    <th className="px-5 py-4 text-sm font-semibold text-gray-700">
                                      {section.table_header?.[0]}
                                    </th>
                                    <th className="px-5 py-4 text-sm font-semibold text-gray-700">
                                      {section.table_header?.[1]}
                                    </th>
                                  </tr>
                                </thead>
                                <tbody>
                                  {section.table.map(([treatment, basis], index) => (
                                    <tr
                                      key={index}
                                      className={
                                        index !== section.table!.length - 1
                                          ? "border-b border-gray-100"
                                          : ""
                                      }
                                    >
                                      <td className="px-5 py-4 text-sm md:text-[15px] text-gray-600 leading-6 align-top">
                                        {treatment}
                                      </td>
                                      <td className="px-5 py-4 text-sm md:text-[15px] text-gray-600 leading-6 align-top">
                                        {basis}
                                      </td>
                                    </tr>
                                  ))}
                                </tbody>
                              </table>
                            </div>
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
                      Versión 1.0 · Elaborado el 14 de septiembre de 2026.
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
         * MODIRA — HEADER DE POLÍTICA DE PRIVACIDAD
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

        .privacy-header-wrapper {
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

        .privacy-header-transparent {
          background: linear-gradient(
            to right,
            #102A66,
            #173B8F
          ) !important;

          box-shadow:
            0 4px 12px rgba(16, 42, 102, 0.18) !important;
        }

        .privacy-header-transparent header {
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

        .privacy-header-scrolled {
          background-color: #ffffff !important;
          box-shadow:
            0 1px 0 rgba(15, 23, 42, 0.06) !important;
        }

        .privacy-header-scrolled header {
          background-color: #ffffff !important;
          box-shadow: none !important;
        }

        /*
         * ========================================================
         * PÁGINA
         * ========================================================
         */

        .privacy-page {
          position: relative;
        }
      `}</style>
    </div>
  );
}
