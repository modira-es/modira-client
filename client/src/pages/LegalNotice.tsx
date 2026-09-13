import { useEffect, useState } from "react";
import Header from "@/components/Header";
import {
  ArrowLeft,
  FileText,
} from "lucide-react";

/*
 * ============================================================
 * MODIRA — AVISO LEGAL
 * ============================================================
 *
 * Diseño y estructura adaptados de las páginas de
 * Términos y Condiciones y Política de Privacidad de MODIRA.
 *
 * El contenido jurídico se corresponde íntegramente con el
 * texto proporcionado para el Aviso Legal de MODIRA.
 * ============================================================
 */

type Block =
  | { type: "p"; text: string }
  | { type: "bullet"; text: string }
  | { type: "numbered"; text: string }
  | { type: "subheading"; text: string }
  | { type: "label"; text: string }
  | { type: "info"; info?: [string, string][] };

type Section = {
  id: string;
  number: string;
  title: string;
  blocks: Block[];
};

const sections: Section[] = [
  
  {
    "id": "objeto-del-sitio-web",
    "number": "1",
    "title": "OBJETO DEL SITIO WEB",
    "blocks": [
      {
        "type": "p",
        "text": "El sitio web https://modira.es tiene como finalidad proporcionar información sobre MODIRA, sus servicios y funcionalidades, así como facilitar el contacto con potenciales clientes y, cuando corresponda, permitir la solicitud de una auditoría o análisis inicial."
      },
      {
        "type": "p",
        "text": "MODIRA presta servicios relacionados con la automatización y mejora de procesos empresariales, pudiendo incluir, entre otros:"
      },
      {
        "type": "bullet",
        "text": "análisis de procesos;"
      },
      {
        "type": "bullet",
        "text": "auditorías;"
      },
      {
        "type": "bullet",
        "text": "identificación de oportunidades de automatización;"
      },
      {
        "type": "bullet",
        "text": "diseño de automatizaciones;"
      },
      {
        "type": "bullet",
        "text": "desarrollo e implementación;"
      },
      {
        "type": "bullet",
        "text": "integración de herramientas y servicios;"
      },
      {
        "type": "bullet",
        "text": "documentación;"
      },
      {
        "type": "bullet",
        "text": "soporte;"
      },
      {
        "type": "bullet",
        "text": "mantenimiento;"
      },
      {
        "type": "bullet",
        "text": "mejoras y modificaciones de soluciones existentes."
      },
      {
        "type": "p",
        "text": "Los servicios concretos que finalmente se presten dependerán de las características y necesidades de cada proyecto y de las condiciones establecidas en el correspondiente presupuesto, propuesta o contrato."
      },
      {
        "type": "p",
        "text": "La información publicada en el sitio web, incluyendo la relativa a servicios, funcionalidades y precios, tendrá carácter informativo y orientativo, salvo que expresamente se indique lo contrario."
      },
      {
        "type": "p",
        "text": "La información publicada en la web no constituye por sí misma una oferta contractual ni determina necesariamente el precio final de un proyecto."
      }
    ]
  },
  {
    "id": "ambito-profesional",
    "number": "2",
    "title": "ÁMBITO PROFESIONAL DE MODIRA",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA está actualmente orientada a:"
      },
      {
        "type": "bullet",
        "text": "empresas;"
      },
      {
        "type": "bullet",
        "text": "personas trabajadoras autónomas;"
      },
      {
        "type": "bullet",
        "text": "profesionales que actúen en el marco de su actividad económica o profesional."
      },
      {
        "type": "p",
        "text": "Los servicios de MODIRA están diseñados actualmente para relaciones de carácter empresarial o profesional (B2B)."
      },
      {
        "type": "p",
        "text": "Los Términos y Condiciones de MODIRA regulan específicamente la utilización del Área de Cliente, las auditorías, proyectos, presupuestos, contratación de servicios, pagos y demás aspectos de la relación contractual."
      },
      {
        "type": "p",
        "text": "Los presentes textos legales deberán interpretarse conjuntamente con dichos Términos y Condiciones cuando exista una relación contractual entre MODIRA y un cliente."
      }
    ]
  },
  {
    "id": "acceso-utilizacion",
    "number": "3",
    "title": "ACCESO Y UTILIZACIÓN DEL SITIO WEB",
    "blocks": [
      {
        "type": "p",
        "text": "El acceso al sitio web de MODIRA es, con carácter general, libre y gratuito."
      },
      {
        "type": "p",
        "text": "El usuario se compromete a utilizar el sitio web de forma diligente, correcta y conforme a:"
      },
      {
        "type": "bullet",
        "text": "la legislación aplicable;"
      },
      {
        "type": "bullet",
        "text": "el presente Aviso Legal;"
      },
      {
        "type": "bullet",
        "text": "los Términos y Condiciones de MODIRA, cuando resulten aplicables;"
      },
      {
        "type": "bullet",
        "text": "la buena fe;"
      },
      {
        "type": "bullet",
        "text": "el orden público;"
      },
      {
        "type": "bullet",
        "text": "los derechos de terceros."
      },
      {
        "type": "p",
        "text": "Queda prohibido utilizar el sitio web para realizar actividades ilícitas, fraudulentas, abusivas o contrarias a la legislación vigente."
      },
      {
        "type": "p",
        "text": "Asimismo, el usuario deberá abstenerse de realizar actuaciones que puedan dañar, inutilizar, sobrecargar o impedir el normal funcionamiento del sitio web, sus sistemas o sus medidas de seguridad."
      }
    ]
  },
  {
    "id": "area-de-cliente",
    "number": "4",
    "title": "ÁREA DE CLIENTE",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA dispone de funcionalidades destinadas a clientes mediante un Área de Cliente."
      },
      {
        "type": "p",
        "text": "Desde dicha área podrán realizarse, cuando las funcionalidades correspondientes estén habilitadas:"
      },
      {
        "type": "bullet",
        "text": "gestión de la cuenta;"
      },
      {
        "type": "bullet",
        "text": "solicitud o seguimiento de proyectos;"
      },
      {
        "type": "bullet",
        "text": "gestión de auditorías;"
      },
      {
        "type": "bullet",
        "text": "comunicación con MODIRA;"
      },
      {
        "type": "bullet",
        "text": "recepción y aceptación de presupuestos;"
      },
      {
        "type": "bullet",
        "text": "consulta de información relacionada con proyectos;"
      },
      {
        "type": "bullet",
        "text": "gestión de documentación;"
      },
      {
        "type": "bullet",
        "text": "facturación;"
      },
      {
        "type": "bullet",
        "text": "realización de pagos;"
      },
      {
        "type": "bullet",
        "text": "utilización de determinadas funcionalidades de la plataforma."
      },
      {
        "type": "p",
        "text": "El acceso al Área de Cliente puede requerir la creación de una cuenta y la aceptación de los Términos y Condiciones correspondientes."
      },
      {
        "type": "p",
        "text": "El inicio de un proyecto desde el Área de Cliente no implica por sí mismo la contratación de un servicio ni genera automáticamente una obligación de pago."
      },
      {
        "type": "p",
        "text": "La contratación se producirá cuando exista un presupuesto o documento contractual aplicable y este haya sido aceptado conforme al procedimiento establecido por MODIRA."
      }
    ]
  },
  {
    "id": "presupuestos-contratacion",
    "number": "5",
    "title": "PRESUPUESTOS Y CONTRATACIÓN",
    "blocks": [
      {
        "type": "p",
        "text": "La información general disponible en el sitio web tiene carácter orientativo."
      },
      {
        "type": "p",
        "text": "Cuando MODIRA determine que procede realizar un proyecto, podrá elaborar un presupuesto en el que se establecerán, cuando corresponda:"
      },
      {
        "type": "bullet",
        "text": "descripción del servicio;"
      },
      {
        "type": "bullet",
        "text": "alcance;"
      },
      {
        "type": "bullet",
        "text": "entregables;"
      },
      {
        "type": "bullet",
        "text": "precio;"
      },
      {
        "type": "bullet",
        "text": "impuestos aplicables;"
      },
      {
        "type": "bullet",
        "text": "condiciones de pago;"
      },
      {
        "type": "bullet",
        "text": "plazos o estimaciones de ejecución;"
      },
      {
        "type": "bullet",
        "text": "condiciones particulares;"
      },
      {
        "type": "bullet",
        "text": "garantías;"
      },
      {
        "type": "bullet",
        "text": "mantenimiento;"
      },
      {
        "type": "bullet",
        "text": "otras condiciones relevantes."
      },
      {
        "type": "p",
        "text": "El precio y las condiciones económicas aplicables a cada proyecto serán las establecidas en el presupuesto correspondiente y, cuando proceda, en las condiciones particulares o contrato aplicable."
      },
      {
        "type": "p",
        "text": "La aceptación del presupuesto podrá realizarse electrónicamente desde el Área de Cliente o mediante el mecanismo que MODIRA habilite para la contratación correspondiente."
      },
      {
        "type": "p",
        "text": "Las condiciones particulares expresamente aceptadas para un proyecto podrán complementar las condiciones generales de MODIRA."
      }
    ]
  },
  {
    "id": "auditorias-analisis-iniciales",
    "number": "6",
    "title": "AUDITORÍAS Y ANÁLISIS INICIALES",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA podrá ofrecer una auditoría o análisis inicial gratuito destinado a identificar necesidades, procesos susceptibles de mejora y posibles oportunidades de automatización."
      },
      {
        "type": "p",
        "text": "La realización de dicha auditoría no garantiza:"
      },
      {
        "type": "bullet",
        "text": "un número determinado de automatizaciones;"
      },
      {
        "type": "bullet",
        "text": "un ahorro económico determinado;"
      },
      {
        "type": "bullet",
        "text": "un ahorro de tiempo determinado;"
      },
      {
        "type": "bullet",
        "text": "que todos los procesos puedan automatizarse;"
      },
      {
        "type": "bullet",
        "text": "la elaboración posterior de una propuesta económica;"
      },
      {
        "type": "bullet",
        "text": "la contratación posterior de un proyecto."
      },
      {
        "type": "p",
        "text": "La auditoría tampoco obliga por sí misma a MODIRA ni al potencial cliente a contratar posteriormente un servicio."
      },
      {
        "type": "p",
        "text": "Su finalidad es facilitar un análisis inicial y, cuando proceda, servir como base para una posible propuesta de servicios."
      }
    ]
  },
  {
    "id": "propiedad-intelectual-industrial",
    "number": "7",
    "title": "PROPIEDAD INTELECTUAL E INDUSTRIAL",
    "blocks": [
      {
        "type": "p",
        "text": "Todos los contenidos propios incluidos en el sitio web y en la plataforma MODIRA, salvo aquellos que pertenezcan legítimamente a terceros, podrán estar protegidos por la legislación sobre propiedad intelectual e industrial."
      },
      {
        "type": "p",
        "text": "Entre otros, podrán comprender:"
      },
      {
        "type": "bullet",
        "text": "software;"
      },
      {
        "type": "bullet",
        "text": "código;"
      },
      {
        "type": "bullet",
        "text": "diseño;"
      },
      {
        "type": "bullet",
        "text": "interfaz;"
      },
      {
        "type": "bullet",
        "text": "estructura;"
      },
      {
        "type": "bullet",
        "text": "logotipos;"
      },
      {
        "type": "bullet",
        "text": "marca MODIRA;"
      },
      {
        "type": "bullet",
        "text": "textos;"
      },
      {
        "type": "bullet",
        "text": "gráficos;"
      },
      {
        "type": "bullet",
        "text": "elementos visuales;"
      },
      {
        "type": "bullet",
        "text": "contenidos propios;"
      },
      {
        "type": "bullet",
        "text": "documentación;"
      },
      {
        "type": "bullet",
        "text": "otros elementos desarrollados o utilizados legítimamente por MODIRA."
      },
      {
        "type": "p",
        "text": "Los programas de ordenador y otras creaciones originales pueden encontrarse protegidos por la legislación española de propiedad intelectual. La normativa reconoce al titular de los derechos de explotación, entre otros, los derechos exclusivos de reproducción, distribución, comunicación pública y transformación, salvo las excepciones legalmente previstas. (BOE: https://www.boe.es/eli/es/rdlg/1996/04/12/1/con/20200708)"
      },
      {
        "type": "p",
        "text": "Salvo autorización expresa de MODIRA o cuando la legislación aplicable permita lo contrario, queda prohibido:"
      },
      {
        "type": "bullet",
        "text": "copiar;"
      },
      {
        "type": "bullet",
        "text": "reproducir;"
      },
      {
        "type": "bullet",
        "text": "distribuir;"
      },
      {
        "type": "bullet",
        "text": "modificar;"
      },
      {
        "type": "bullet",
        "text": "transformar;"
      },
      {
        "type": "bullet",
        "text": "descompilar;"
      },
      {
        "type": "bullet",
        "text": "realizar ingeniería inversa;"
      },
      {
        "type": "bullet",
        "text": "comercializar;"
      },
      {
        "type": "bullet",
        "text": "explotar;"
      },
      {
        "type": "bullet",
        "text": "redistribuir;"
      },
      {
        "type": "p",
        "text": "los elementos protegidos de MODIRA."
      },
      {
        "type": "p",
        "text": "La contratación de un servicio de desarrollo o automatización no implica por sí misma la transmisión de los derechos de propiedad intelectual sobre la plataforma MODIRA, su código fuente, herramientas internas o componentes preexistentes."
      },
      {
        "type": "p",
        "text": "Los derechos correspondientes a entregables específicamente desarrollados para un cliente podrán determinarse en el presupuesto, contrato o condiciones particulares del proyecto."
      }
    ]
  },
  {
    "id": "contenidos-materiales-cliente",
    "number": "8",
    "title": "CONTENIDOS Y MATERIALES DEL CLIENTE",
    "blocks": [
      {
        "type": "p",
        "text": "Los contenidos, documentos, información, marcas, procedimientos y demás materiales proporcionados por un cliente seguirán perteneciendo a su legítimo titular."
      },
      {
        "type": "p",
        "text": "El cliente será responsable de disponer de los derechos, autorizaciones y legitimaciones necesarias para proporcionar dichos materiales a MODIRA y permitir su utilización en la ejecución del proyecto."
      },
      {
        "type": "p",
        "text": "MODIRA podrá utilizar dichos materiales únicamente en la medida necesaria para prestar los servicios contratados y de acuerdo con las condiciones aplicables al proyecto."
      },
      {
        "type": "p",
        "text": "Cuando dichos materiales incluyan datos personales tratados por cuenta del cliente, se aplicarán además las condiciones correspondientes en materia de protección de datos y, cuando resulte legalmente necesario, el correspondiente Acuerdo de Encargo del Tratamiento (DPA)."
      }
    ]
  },
  {
    "id": "servicios-herramientas-terceros",
    "number": "9",
    "title": "SERVICIOS, HERRAMIENTAS Y PLATAFORMAS DE TERCEROS",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA puede utilizar o integrarse con servicios, herramientas, APIs, plataformas o tecnologías proporcionadas por terceros."
      },
      {
        "type": "p",
        "text": "Estos servicios pueden estar sujetos a sus propias:"
      },
      {
        "type": "bullet",
        "text": "condiciones de uso;"
      },
      {
        "type": "bullet",
        "text": "políticas de privacidad;"
      },
      {
        "type": "bullet",
        "text": "limitaciones técnicas;"
      },
      {
        "type": "bullet",
        "text": "precios;"
      },
      {
        "type": "bullet",
        "text": "condiciones de disponibilidad;"
      },
      {
        "type": "bullet",
        "text": "modificaciones;"
      },
      {
        "type": "bullet",
        "text": "políticas de seguridad."
      },
      {
        "type": "p",
        "text": "MODIRA no controla directamente los servicios de terceros y, por tanto, no puede garantizar su disponibilidad, continuidad o funcionamiento permanente."
      },
      {
        "type": "p",
        "text": "Las modificaciones, interrupciones o cambios efectuados por proveedores externos podrán afectar a determinadas funcionalidades o integraciones de MODIRA."
      },
      {
        "type": "p",
        "text": "Cuando corresponda, la información relativa a proveedores tecnológicos y al tratamiento de datos personales realizado mediante dichos servicios se encuentra desarrollada en la Política de Privacidad de MODIRA."
      }
    ]
  },
  {
    "id": "responsabilidad",
    "number": "10",
    "title": "RESPONSABILIDAD",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA procurará mantener el sitio web y sus servicios en condiciones adecuadas de funcionamiento y adoptará medidas razonables para corregir incidencias cuando resulte posible."
      },
      {
        "type": "p",
        "text": "No obstante, no se garantiza que el sitio web o sus funcionalidades estén disponibles de forma permanente, continua e ininterrumpida."
      },
      {
        "type": "p",
        "text": "La disponibilidad puede verse afectada, entre otras circunstancias, por:"
      },
      {
        "type": "bullet",
        "text": "tareas de mantenimiento;"
      },
      {
        "type": "bullet",
        "text": "actualizaciones;"
      },
      {
        "type": "bullet",
        "text": "incidencias técnicas;"
      },
      {
        "type": "bullet",
        "text": "fallos de infraestructura;"
      },
      {
        "type": "bullet",
        "text": "problemas de conectividad;"
      },
      {
        "type": "bullet",
        "text": "servicios de terceros;"
      },
      {
        "type": "bullet",
        "text": "cambios tecnológicos;"
      },
      {
        "type": "bullet",
        "text": "incidentes de seguridad;"
      },
      {
        "type": "bullet",
        "text": "acontecimientos fuera del control razonable de MODIRA."
      },
      {
        "type": "p",
        "text": "MODIRA responderá conforme a la legislación aplicable."
      },
      {
        "type": "p",
        "text": "Sin perjuicio de las responsabilidades que legalmente no puedan excluirse o limitarse, MODIRA no será responsable de daños derivados de circunstancias que razonablemente no dependan de su actuación, incluyendo, cuando corresponda:"
      },
      {
        "type": "bullet",
        "text": "fallos de servicios de terceros;"
      },
      {
        "type": "bullet",
        "text": "cambios de APIs;"
      },
      {
        "type": "bullet",
        "text": "indisponibilidad de herramientas externas;"
      },
      {
        "type": "bullet",
        "text": "información incorrecta proporcionada por el cliente;"
      },
      {
        "type": "bullet",
        "text": "modificaciones realizadas por el cliente o terceros;"
      },
      {
        "type": "bullet",
        "text": "utilización de automatizaciones fuera del alcance contratado;"
      },
      {
        "type": "bullet",
        "text": "decisiones empresariales adoptadas por el cliente a partir de información proporcionada por MODIRA AI;"
      },
      {
        "type": "bullet",
        "text": "acontecimientos de fuerza mayor."
      },
      {
        "type": "p",
        "text": "Esta regulación es coherente con la limitación de responsabilidad establecida en los Términos y Condiciones."
      },
      {
        "type": "p",
        "text": "En ningún caso el presente Aviso Legal pretende excluir o limitar responsabilidades que legalmente no puedan ser excluidas o limitadas."
      }
    ]
  },
  {
    "id": "seguridad",
    "number": "11",
    "title": "SEGURIDAD",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA aplica medidas técnicas y organizativas destinadas a proteger la plataforma y la información gestionada a través de ella."
      },
      {
        "type": "p",
        "text": "Entre otras medidas, la arquitectura de MODIRA incorpora mecanismos de autenticación, control de acceso, aislamiento entre empresas, políticas de seguridad, protección frente al abuso, limitación de solicitudes y controles específicos para operaciones sensibles."
      },
      {
        "type": "p",
        "text": "No obstante, ningún sistema conectado a Internet puede garantizar una seguridad absoluta."
      },
      {
        "type": "p",
        "text": "El usuario deberá adoptar también las medidas necesarias para proteger sus credenciales, dispositivos, sistemas y accesos."
      }
    ]
  },
  {
    "id": "proteccion-datos-personales",
    "number": "12",
    "title": "PROTECCIÓN DE DATOS PERSONALES",
    "blocks": [
      {
        "type": "p",
        "text": "El tratamiento de datos personales realizado en relación con el sitio web, la plataforma y los servicios de MODIRA se regula mediante la Política de Privacidad de MODIRA."
      },
      {
        "type": "p",
        "text": "Cuando MODIRA actúe como responsable del tratamiento, serán aplicables las condiciones establecidas en dicha Política."
      },
      {
        "type": "p",
        "text": "Cuando MODIRA trate datos personales por cuenta de una empresa cliente, se formalizará el correspondiente Acuerdo de Encargo del Tratamiento cuando resulte legalmente necesario."
      },
      {
        "type": "p",
        "text": "La Política de Privacidad desarrolla, entre otras cuestiones:"
      },
      {
        "type": "bullet",
        "text": "responsables del tratamiento;"
      },
      {
        "type": "bullet",
        "text": "finalidades;"
      },
      {
        "type": "bullet",
        "text": "bases jurídicas;"
      },
      {
        "type": "bullet",
        "text": "categorías de datos;"
      },
      {
        "type": "bullet",
        "text": "conservación;"
      },
      {
        "type": "bullet",
        "text": "destinatarios;"
      },
      {
        "type": "bullet",
        "text": "proveedores;"
      },
      {
        "type": "bullet",
        "text": "transferencias internacionales;"
      },
      {
        "type": "bullet",
        "text": "derechos de los interesados;"
      },
      {
        "type": "bullet",
        "text": "medidas de seguridad;"
      },
      {
        "type": "bullet",
        "text": "determinados tratamientos mediante inteligencia artificial."
      },
      {
        "type": "p",
        "text": "La información exigida por la normativa de protección de datos se proporciona específicamente mediante la Política de Privacidad y las informaciones correspondientes a cada tratamiento. El RGPD exige, entre otros extremos, informar sobre la identidad y datos de contacto del responsable, finalidades, bases jurídicas y, cuando corresponda, datos del delegado de protección de datos. (EUR-Lex: https://eur-lex.europa.eu/eli/reg/2016/679/oj/spa)"
      },
      {
        "type": "p",
        "text": "No existe actualmente un Delegado de Protección de Datos designado por MODIRA, al no haberse determinado la obligación de designarlo conforme a las circunstancias actuales de la actividad."
      },
      {
        "type": "p",
        "text": "Si en el futuro las características o escala de los tratamientos determinaran la obligación legal de disponer de un DPD, esta información será actualizada."
      }
    ]
  },
  {
    "id": "cookies-tecnologias-similares",
    "number": "13",
    "title": "COOKIES Y TECNOLOGÍAS SIMILARES",
    "blocks": [
      {
        "type": "p",
        "text": "El uso de cookies y tecnologías similares en el sitio web de MODIRA se regula mediante la Política de Cookies."
      },
      {
        "type": "p",
        "text": "Las cookies o tecnologías que requieran consentimiento se gestionarán mediante el mecanismo correspondiente."
      },
      {
        "type": "p",
        "text": "La aceptación del presente Aviso Legal o de los Términos y Condiciones no constituye por sí misma consentimiento para la utilización de cookies que legalmente requieran consentimiento."
      }
    ]
  },
  {
    "id": "comunicaciones",
    "number": "14",
    "title": "COMUNICACIONES",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA podrá utilizar los datos de contacto facilitados por los usuarios o clientes para realizar comunicaciones necesarias relacionadas con:"
      },
      {
        "type": "bullet",
        "text": "cuentas;"
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
        "text": "contratación;"
      },
      {
        "type": "bullet",
        "text": "facturación;"
      },
      {
        "type": "bullet",
        "text": "seguridad;"
      },
      {
        "type": "bullet",
        "text": "incidencias;"
      },
      {
        "type": "bullet",
        "text": "soporte;"
      },
      {
        "type": "bullet",
        "text": "mantenimiento;"
      },
      {
        "type": "bullet",
        "text": "funcionamiento de los servicios."
      },
      {
        "type": "p",
        "text": "Las comunicaciones comerciales estarán sometidas a la legislación aplicable y, cuando sea necesario, requerirán el consentimiento correspondiente."
      },
      {
        "type": "p",
        "text": "El consentimiento para recibir comunicaciones comerciales será independiente de la aceptación del presente Aviso Legal y de los Términos y Condiciones."
      }
    ]
  },
  {
    "id": "enlaces-terceros",
    "number": "15",
    "title": "ENLACES A SITIOS WEB DE TERCEROS",
    "blocks": [
      {
        "type": "p",
        "text": "El sitio web de MODIRA podrá contener enlaces a páginas, servicios o recursos pertenecientes a terceros."
      },
      {
        "type": "p",
        "text": "MODIRA no controla necesariamente el contenido, funcionamiento, disponibilidad, políticas o prácticas de dichos sitios externos."
      },
      {
        "type": "p",
        "text": "La inclusión de un enlace no implica necesariamente una relación, aprobación o recomendación del contenido o servicio enlazado."
      },
      {
        "type": "p",
        "text": "El usuario deberá consultar las condiciones y políticas propias de cada servicio externo cuando acceda a ellos."
      }
    ]
  },
  {
    "id": "modificaciones-sitio-aviso",
    "number": "16",
    "title": "MODIFICACIONES DEL SITIO WEB Y DEL AVISO LEGAL",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA podrá modificar, actualizar, ampliar o retirar contenidos, funcionalidades o servicios del sitio web cuando resulte necesario."
      },
      {
        "type": "p",
        "text": "Asimismo, este Aviso Legal podrá actualizarse cuando existan:"
      },
      {
        "type": "bullet",
        "text": "cambios legislativos;"
      },
      {
        "type": "bullet",
        "text": "cambios en la actividad;"
      },
      {
        "type": "bullet",
        "text": "modificaciones tecnológicas;"
      },
      {
        "type": "bullet",
        "text": "incorporación de nuevos servicios;"
      },
      {
        "type": "bullet",
        "text": "modificaciones de la plataforma;"
      },
      {
        "type": "bullet",
        "text": "cambios en proveedores;"
      },
      {
        "type": "bullet",
        "text": "cambios en los sistemas de contratación;"
      },
      {
        "type": "bullet",
        "text": "necesidades de seguridad;"
      },
      {
        "type": "bullet",
        "text": "otras circunstancias que hagan necesaria su actualización."
      },
      {
        "type": "p",
        "text": "La versión vigente estará disponible permanentemente en el sitio web."
      },
      {
        "type": "p",
        "text": "Las modificaciones no afectarán retroactivamente a derechos u obligaciones contractuales ya consolidados cuando la legislación aplicable no permita dicha modificación."
      }
    ]
  },
  {
    "id": "legislacion-aplicable",
    "number": "17",
    "title": "LEGISLACIÓN APLICABLE",
    "blocks": [
      {
        "type": "p",
        "text": "El presente Aviso Legal se regirá por la legislación española, sin perjuicio de aquellas normas imperativas que pudieran resultar aplicables."
      },
      {
        "type": "p",
        "text": "En particular, serán de aplicación, cuando corresponda:"
      },
      {
        "type": "bullet",
        "text": "la Ley 34/2002, de Servicios de la Sociedad de la Información y de Comercio Electrónico;"
      },
      {
        "type": "bullet",
        "text": "la normativa española sobre propiedad intelectual e industrial;"
      },
      {
        "type": "bullet",
        "text": "el Reglamento (UE) 2016/679, General de Protección de Datos;"
      },
      {
        "type": "bullet",
        "text": "la Ley Orgánica 3/2018, de Protección de Datos Personales y garantía de los derechos digitales;"
      },
      {
        "type": "bullet",
        "text": "y las demás disposiciones legales que resulten aplicables a la actividad."
      },
      {
        "type": "p",
        "text": "La LSSI establece, entre otras cuestiones, las obligaciones de información general de los prestadores de servicios de la sociedad de la información y su régimen de responsabilidad. (BOE: https://www.boe.es/buscar/act.php?id=BOE-A-2002-13758)"
      }
    ]
  },
  {
    "id": "resolucion-conflictos-jurisdiccion",
    "number": "18",
    "title": "RESOLUCIÓN DE CONFLICTOS Y JURISDICCIÓN",
    "blocks": [
      {
        "type": "p",
        "text": "MODIRA procurará resolver de forma amistosa cualquier discrepancia que pueda surgir en relación con el sitio web o sus servicios."
      },
      {
        "type": "p",
        "text": "Cuando exista una relación contractual entre MODIRA y un cliente, serán aplicables las reglas de jurisdicción y competencia establecidas en los Términos y Condiciones, el presupuesto aceptado y, cuando corresponda, las condiciones particulares o contrato específico."
      },
      {
        "type": "p",
        "text": "Cuando ambas partes actúen como empresarios o profesionales en el marco de su actividad económica, las controversias se someterán a los juzgados y tribunales que resulten competentes conforme a la legislación aplicable."
      },
      {
        "type": "p",
        "text": "En ningún caso esta cláusula pretende alterar las reglas imperativas de competencia judicial que resulten aplicables."
      }
    ]
  },
  {
    "id": "contacto",
    "number": "19",
    "title": "CONTACTO",
    "blocks": [
      {
        "type": "p",
        "text": "Para cualquier cuestión relacionada con este Aviso Legal, el funcionamiento general del sitio web o la actividad de MODIRA, puede contactarse mediante:"
      },
      {
        "type": "info",
        "info": [
          [
            "Correo electrónico",
            "info@modira.es"
          ]
        ]
      },
      {
        "type": "p",
        "text": "Los clientes también podrán utilizar los canales de soporte disponibles dentro del Área de Cliente cuando la consulta esté relacionada con un proyecto o servicio contratado."
      }
    ]
  },
  {
    "id": "version-fecha",
    "number": "20",
    "title": "VERSIÓN Y FECHA",
    "blocks": [
      {
        "type": "info",
        "info": [
          [
            "Documento",
            "Aviso Legal de MODIRA"
          ],
          [
            "Versión",
            "1.0"
          ],
          [
            "Fecha de elaboración",
            "13 de septiembre de 2026"
          ],
          [
            "Fecha de entrada en vigor",
            "13 de septiembre de 2026"
          ],
          [
            "Última actualización",
            "13 de septiembre de 2026"
          ]
        ]
      }
    ]
  },
  {
    "id": "identificacion-del-titular",
    "number": "21",
    "title": "IDENTIFICACIÓN DEL TITULAR",
    "blocks": [
      {
        "type": "p",
        "text": "En cumplimiento de lo dispuesto en la normativa aplicable, y especialmente en la Ley 34/2002, de 11 de julio, de Servicios de la Sociedad de la Información y de Comercio Electrónico (LSSI-CE), se informa de los siguientes datos relativos al titular y responsable del sitio web:"
      },
      {
        "type": "info",
        "info": [
          [
            "Correo electrónico",
            "info@modira.es"
          ],
          [
            "Sitio web",
            "https://modira.es/"
          ],
          [
            "Marca",
            "MODIRA"
          ],
          [
            "Titular / prestador",
            "Adrián Modino Merino"
          ],
          [
            "NIF",
            "06641212P"
          ],
          
          [
            "Domicilio",
            "Calle Lisboa 25"
          ]
          
        ]
      },
      {
        "type": "p",
        "text": "MODIRA es una marca/proyecto titularidad de Adrián Modino Merino."
      },
      {
        "type": "p",
        "text": "El presente Aviso Legal regula las condiciones generales de acceso, navegación y utilización del sitio web de MODIRA, así como la información relativa a la titularidad y responsabilidad sobre sus contenidos y servicios."
      },
      {
        "type": "p",
        "text": "Actualmente, MODIRA opera como proyecto titularidad de una persona física. La información identificativa será actualizada cuando se produzcan cambios en la titularidad, forma jurídica o situación de la actividad."
      }
    ]
  },
];

export default function LegalNotice() {
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
      className={`min-h-screen bg-[#F8FAFC] legal-page ${
        isScrolled ? "legal-scrolled" : "legal-top"
      }`}
    >
      {/* ========================================================
          HEADER
          ======================================================== */}

      <div
        className={`legal-header-wrapper ${
          isScrolled
            ? "legal-header-scrolled"
            : "legal-header-transparent"
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
                    Aviso Legal
                  </h1>

                  <p className="text-base md:text-lg text-gray-500 leading-relaxed max-w-3xl">
                    Información sobre la titularidad, condiciones generales
                    de acceso, navegación y utilización del sitio web de
                    MODIRA, así como sobre sus contenidos y servicios.
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
                        {section.number ? `${section.number}.` : ""}
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

                  <div className="pb-10 mb-10 border-b border-gray-100">
                    <p className="text-sm font-semibold text-[#1E3A8A] mb-2">
                      AVISO LEGAL DE MODIRA
                    </p>
                    <div className="grid sm:grid-cols-2 gap-2 text-sm leading-7 text-gray-500">
                      <p>
                        <span className="font-medium text-gray-700">
                          Última actualización:
                        </span>{" "}
                        13 de septiembre de 2026
                      </p>
                      <p>
                        <span className="font-medium text-gray-700">
                          Versión:
                        </span>{" "}
                        1.0
                      </p>
                    </div>
                  </div>

                  <div className="space-y-14">
                    {sections.map((section) => (
                      <section
                        key={section.id}
                        id={section.id}
                        className="scroll-mt-28"
                      >
                        <div className="flex items-start gap-4 mb-5">
                          <div
                            className={`flex-shrink-0 w-9 h-9 rounded-lg bg-[#EFF6FF] flex items-center justify-center ${
                              !section.number ? "opacity-60" : ""
                            }`}
                          >
                            <span className="text-xs font-bold text-[#1E3A8A]">
                              {section.number || "•"}
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
                                  {block.info?.map(([label, value], infoIndex) => (
                                    <div
                                      key={`${label}-${infoIndex}`}
                                      className={`grid sm:grid-cols-[190px_1fr] gap-2 sm:gap-6 px-5 py-4 ${
                                        infoIndex !== block.info!.length - 1
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
                        </div>
                      </section>
                    ))}
                  </div>

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
         * MODIRA — HEADER DE AVISO LEGAL
         * ========================================================
         *
         * ARRIBA DEL TODO
         * ----------------
         * Header azul.
         *
         * AL HACER SCROLL
         * ----------------
         * Header blanco.
         * ========================================================
         */

        .legal-header-wrapper {
          position: relative;
          z-index: 50;
          min-height: 0;
          transition:
            background-color 250ms ease,
            box-shadow 250ms ease;
        }

        .legal-header-transparent {
          background: linear-gradient(
            to right,
            #102A66,
            #173B8F
          ) !important;

          box-shadow:
            0 4px 12px rgba(16, 42, 102, 0.18) !important;
        }

        .legal-header-transparent header {
          background: linear-gradient(
            to right,
            #102A66,
            #173B8F
          ) !important;

          box-shadow: none !important;
        }

        .legal-header-scrolled {
          background-color: #ffffff !important;
          box-shadow:
            0 1px 0 rgba(15, 23, 42, 0.06) !important;
        }

        .legal-header-scrolled header {
          background-color: #ffffff !important;
          box-shadow: none !important;
        }

        .legal-page {
          position: relative;
        }
      `}</style>
    </div>
  );
}
