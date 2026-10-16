import { useEffect } from "react";
import ClientRoute from "@/components/ClientRoute";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import NotFound from "@/pages/NotFound";
import { Route, Switch } from "wouter";
import ErrorBoundary from "./components/ErrorBoundary";
import { ThemeProvider } from "./contexts/ThemeContext";
import { AuthProvider } from "./contexts/AuthContext";


import Home from "./pages/Home";
import Auth from "./pages/Auth";
import ResetPassword from "./pages/ResetPassword";
import QuotationView from "./pages/QuotationView";
import ClientArea from "./pages/ClientArea";
import Billing from "./pages/Billing";
import DocumentsList from "./pages/DocumentsList";
import ProjectsList from "./components/ProjectsList";
import Quotations from "./pages/Quotations";
import Support from "./pages/Support";
import ClientMaintenance from "./pages/ClientMaintenance";

import PrivacyPolicy from "./pages/PrivacyPolicy";
import CookiePolicy from "./pages/CookiePolicy";
import TermsOfService from "./pages/TermsOfService";
import LegalNotice from "./pages/LegalNotice";
import CookieBanner from "./components/CookieBanner";

import HowWeWorkGuide from "./pages/HowWeWorkGuide";
import ServicesGuide from "./pages/ServicesGuide";
import AboutUs from "./pages/WhoWeAre";
import UserGuide from "./pages/UserGuide";
import AuditConditions from "./pages/AuditConditions";

function Router() {
  return (
    <Switch>
      {/* Página principal */}
      <Route path="/" component={Home} />

      {/* Autenticación de clientes */}
      <Route path="/auth" component={Auth} />
      <Route
        path="/auth/reset-password"
        component={ResetPassword}
      />

      {/* Presupuesto individual */}
      <Route
        path="/presupuesto/:id"
        component={QuotationView}
      />

      {/* Guías públicas */}
      <Route
        path="/como-trabajamos"
        component={HowWeWorkGuide}
      />

      <Route
        path="/servicios"
        component={ServicesGuide}
      />

      <Route
        path="/quienes-somos"
        component={AboutUs}
      />

      <Route
        path="/guia-usuario"
        component={UserGuide}
      />

      <Route
        path="/condiciones-auditoria-gratuita"
        component={AuditConditions}
      />

      {/* Área de cliente */}
      <Route
        path="/area-cliente"
        component={() => (
          <ClientRoute>
            <ClientArea />
          </ClientRoute>
        )}
      />

      <Route
        path="/area-cliente/proyectos"
        component={() => (
          <ClientRoute>
            <ProjectsList />
          </ClientRoute>
        )}
      />

      <Route
        path="/area-cliente/presupuestos"
        component={() => (
          <ClientRoute>
            <Quotations />
          </ClientRoute>
        )}
      />

      <Route
        path="/area-cliente/facturacion"
        component={() => (
          <ClientRoute>
            <Billing />
          </ClientRoute>
        )}
      />
      <Route
  path="/area-cliente/documentos"
  component={() => (
    <ClientRoute>
      <DocumentsList />
    </ClientRoute>
  )}
/>
      <Route
        path="/area-cliente/soporte"
        component={() => (
          <ClientRoute>
            <Support />
          </ClientRoute>
        )}
      />
      <Route
  path="/area-cliente/mantenimiento"
  component={() => (
    <ClientRoute>
      <ClientMaintenance />
    </ClientRoute>
  )}
/>
<Route path="/area-cliente/mantenimiento/personalizado" component={ClientMaintenance} />
<Route
  path="/area-cliente/mantenimiento/planes"
  component={() => (
    <ClientRoute>
      <ClientMaintenance />
    </ClientRoute>
  )}
/>

      {/* Documentación legal */}
      <Route
        path="/politica-privacidad"
        component={PrivacyPolicy}
      />

      <Route
        path="/politica-cookies"
        component={CookiePolicy}
      />

      <Route
        path="/terminos"
        component={TermsOfService}
      />

      <Route
        path="/aviso-legal"
        component={LegalNotice}
      />

      {/* Página 404 */}
      <Route path="/404" component={NotFound} />

      {/* Ruta fallback */}
      <Route component={NotFound} />
    </Switch>
  );
}

function App() {
  useEffect(() => {
    const savedScroll = sessionStorage.getItem(
      "modira_restore_scroll"
    );

    if (!savedScroll) return;

    sessionStorage.removeItem("modira_restore_scroll");

    const scrollY = Number(savedScroll);

    if (!Number.isFinite(scrollY)) return;

    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        window.scrollTo({
          top: scrollY,
          behavior: "instant",
        });
      });
    });
  }, []);

  return (
    <ErrorBoundary>
      <AuthProvider>
        <ThemeProvider defaultTheme="light">
          <TooltipProvider>
            <Toaster />
            <Router />
            <CookieBanner />
          </TooltipProvider>
        </ThemeProvider>
      </AuthProvider>
    </ErrorBoundary>
  );
}

export default App;