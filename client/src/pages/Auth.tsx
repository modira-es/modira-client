import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Link, useLocation } from "wouter";
import {
  AlertCircle,
  CheckCircle,
  Eye,
  EyeOff,
} from "lucide-react";
import { PasswordStrengthIndicator } from "@/components/PasswordStrengthIndicator";
import { useRef, useState } from "react";
import { useAuth } from "@/contexts/AuthContext";
import {
  Turnstile,
  type TurnstileInstance,
} from "@marsidev/react-turnstile";

type AuthMode =
  | "login"
  | "register"
  | "forgot-password"
  | "complete-legal";

export default function Auth() {
  const [, setLocation] = useLocation();

  const {
    signIn,
    signUp,
    resetPassword,
    completeRegistrationLegalRequirements,
    getRegistrationStatus,
    loading: authLoading,
  } = useAuth();

  const [mode, setMode] =
    useState<AuthMode>("login");

  const [showPassword, setShowPassword] =
    useState(false);

  const [showConfirmPassword, setShowConfirmPassword] =
    useState(false);

  const [error, setError] =
    useState<string | null>(null);

  const [success, setSuccess] =
    useState<string | null>(null);

  const [loading, setLoading] =
    useState(false);

  const [captchaToken, setCaptchaToken] =
    useState<string | null>(null);

  const loginCaptchaRef =
    useRef<TurnstileInstance | null>(null);

  const [loginForm, setLoginForm] = useState({
    email: "",
    password: "",
  });

  const [registerForm, setRegisterForm] =
    useState({
      nombre: "",
      email: "",
      password: "",
      confirmPassword: "",
      empresa: "",
    });

  const [forgotForm, setForgotForm] =
    useState({
      email: "",
    });

  /*
   * Requisitos legales seleccionados para el registro.
   *
   * No se envían documentos, versiones, hashes ni IP al backend.
   * Solo se utiliza el estado de las dos casillas obligatorias
   * para permitir al usuario avanzar en la interfaz.
   */
  const [legalAccepted, setLegalAccepted] =
    useState({
      terms: false,
      privacy: false,
    });

  const handleLogin = async (
    e: React.FormEvent
  ) => {
    e.preventDefault();

    setError(null);
    setSuccess(null);

    if (!captchaToken) {
      setError(
        "Completa la verificación de seguridad antes de iniciar sesión."
      );
      return;
    }

    setLoading(true);

    try {
      const result = await signIn(
        loginForm.email,
        loginForm.password,
        captchaToken
      );

      if (!result.success) {
        setError(
          result.error ||
            "Error al iniciar sesión"
        );
        return;
      }

      /*
       * Una vez autenticado, comprobamos si la cuenta
       * necesita completar los requisitos legales.
       */
      const statusResult =
        await getRegistrationStatus();

      if (!statusResult.success) {
        setError(
          statusResult.error ||
            "No se ha podido comprobar el estado del registro."
        );
        return;
      }

      if (
        statusResult.status ===
        "pending_legal"
      ) {
        setMode("complete-legal");
        setSuccess(
          "Tu correo ha sido confirmado. Completa ahora los requisitos legales para activar tu cuenta."
        );
        return;
      }

      setSuccess(
        "¡Iniciaste sesión exitosamente!"
      );

      setTimeout(() => {
        setLocation("/area-cliente");
      }, 1500);
    } catch (err: any) {
      setError(
        err.message ||
          "Error al iniciar sesión"
      );
    } finally {
      setLoading(false);

      setCaptchaToken(null);
      loginCaptchaRef.current?.reset();
    }
  };

  const handleRegister = async (
    e: React.FormEvent
  ) => {
    e.preventDefault();

    setError(null);
    setSuccess(null);

    if (!registerForm.nombre.trim()) {
      setError("El nombre es requerido");
      return;
    }

    if (!registerForm.email.includes("@")) {
      setError(
        "El correo electrónico no es válido"
      );
      return;
    }

    if (registerForm.password.length < 10) {
      setError(
        "La contraseña debe tener al menos 10 caracteres"
      );
      return;
    }

    if (
      registerForm.password !==
      registerForm.confirmPassword
    ) {
      setError(
        "Las contraseñas no coinciden"
      );
      return;
    }

    if (!legalAccepted.terms) {
      setError(
        "Debes aceptar las Condiciones de Uso de MODIRA."
      );
      return;
    }

    if (!legalAccepted.privacy) {
      setError(
        "Debes confirmar que has sido informado/a sobre el tratamiento de tus datos personales."
      );
      return;
    }

    if (!captchaToken) {
      setError(
        "Completa la verificación de seguridad antes de registrarte."
      );
      return;
    }

    setLoading(true);

    try {
      const result = await signUp(
        registerForm.email,
        registerForm.password,
        registerForm.nombre,
        registerForm.empresa,
        captchaToken
      );

      if (!result.success) {
        setError(
          result.error ||
            "Error al registrarse"
        );
        return;
      }

      /*
       * Las casillas son obligatorias para permitir el registro,
       * pero todavía NO llamamos a la RPC legal aquí.
       *
       * Con confirmación de email obligatoria, signUp() puede
       * no proporcionar una sesión autenticada. La RPC se
       * ejecutará después de confirmar el correo e iniciar sesión.
       */
      setSuccess(
        "¡Registro iniciado! Hemos enviado un correo electrónico para confirmar tu cuenta. Después de confirmarlo, inicia sesión para completar el registro."
      );

      setTimeout(() => {
        setMode("login");

        setLoginForm({
          email: registerForm.email,
          password: "",
        });

        setRegisterForm({
          nombre: "",
          email: "",
          password: "",
          confirmPassword: "",
          empresa: "",
        });

        setLegalAccepted({
          terms: false,
          privacy: false,
        });

        setCaptchaToken(null);
      }, 2500);
    } catch (err: any) {
      setError(
        err.message ||
          "Error al registrarse"
      );
    } finally {
      setLoading(false);
      setCaptchaToken(null);
    }
  };

  const handleCompleteLegal = async (
    e: React.FormEvent
  ) => {
    e.preventDefault();

    setError(null);
    setSuccess(null);

    if (!legalAccepted.terms) {
      setError(
        "Debes aceptar las Condiciones de Uso de MODIRA."
      );
      return;
    }

    if (!legalAccepted.privacy) {
      setError(
        "Debes confirmar que has sido informado/a sobre el tratamiento de tus datos personales."
      );
      return;
    }

    setLoading(true);

    try {
      const result =
  await completeRegistrationLegalRequirements(
    legalAccepted.terms,
    legalAccepted.privacy
  );

      if (!result.success) {
        setError(
          result.error ||
            "No se han podido completar los requisitos legales del registro."
        );
        return;
      }

      setSuccess(
        "¡Registro completado correctamente! Tu cuenta ya está activa."
      );

      setTimeout(() => {
        setLocation("/area-cliente");
      }, 1200);
    } catch (err: any) {
      setError(
        err.message ||
          "No se han podido completar los requisitos legales del registro."
      );
    } finally {
      setLoading(false);
    }
  };

  const handleForgotPassword = async (
    e: React.FormEvent
  ) => {
    e.preventDefault();

    setError(null);
    setSuccess(null);

    if (!captchaToken) {
      setError(
        "Completa la verificación de seguridad antes de solicitar la recuperación."
      );
      return;
    }

    setLoading(true);

    try {
      const result = await resetPassword(
        forgotForm.email,
        captchaToken
      );

      if (!result.success) {
        setError(
          result.error ||
            "Error al solicitar recuperación de contraseña"
        );
        return;
      }

      setSuccess(
        "Si existe una cuenta asociada a este correo, recibirás un enlace para restablecer tu contraseña. Revisa tu bandeja de entrada y la carpeta de spam."
      );

      setTimeout(() => {
        setMode("login");
        setForgotForm({ email: "" });
        setCaptchaToken(null);
      }, 2000);
    } catch (err: any) {
      setError(
        err.message ||
          "Error al solicitar recuperación de contraseña"
      );
    } finally {
      setLoading(false);
    }
  };

  const legalComplete =
    legalAccepted.terms &&
    legalAccepted.privacy;

  return (
    <div className="min-h-screen bg-gradient-to-br from-white via-[#F5F7FA] to-white flex items-center justify-center p-4">
      <Card className="w-full max-w-md border-2 border-gray-200 shadow-xl">
        <div className="p-8">

          <div className="mb-8 text-center">
            <h1 className="text-3xl font-bold text-[#1E3A8A] mb-2">
              Modira
            </h1>

            <p className="text-gray-600">
              {mode === "login"
                ? "Inicia sesión en tu cuenta"
                : mode === "register"
                ? "Crea una nueva cuenta"
                : mode === "complete-legal"
                ? "Completa tu registro"
                : "Recupera tu contraseña"}
            </p>
          </div>

          {error && (
            <div className="mb-6 p-4 bg-red-50 border-l-4 border-red-500 rounded">
              <div className="flex gap-3">
                <AlertCircle className="h-5 w-5 text-red-600 flex-shrink-0 mt-0.5" />

                <p className="text-sm text-red-700">
                  {error}
                </p>
              </div>
            </div>
          )}

          {success && (
            <div className="mb-6 p-4 bg-green-50 border-l-4 border-green-500 rounded">
              <div className="flex gap-3">
                <CheckCircle className="h-5 w-5 text-green-600 flex-shrink-0 mt-0.5" />

                <p className="text-sm text-green-700">
                  {success}
                </p>
              </div>
            </div>
          )}

          {mode === "login" && (
            <form
              onSubmit={handleLogin}
              className="space-y-4"
            >
              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Correo electrónico
                </label>

                <Input
                  type="email"
                  placeholder="tu@email.com"
                  value={loginForm.email}
                  onChange={(e) =>
                    setLoginForm({
                      ...loginForm,
                      email: e.target.value,
                    })
                  }
                  required
                  disabled={
                    loading ||
                    authLoading
                  }
                  className="w-full"
                />
              </div>

              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Contraseña
                </label>

                <div className="relative">
                  <Input
                    type={
                      showPassword
                        ? "text"
                        : "password"
                    }
                    placeholder="••••••••"
                    value={
                      loginForm.password
                    }
                    onChange={(e) =>
                      setLoginForm({
                        ...loginForm,
                        password:
                          e.target.value,
                      })
                    }
                    required
                    disabled={
                      loading ||
                      authLoading
                    }
                    className="w-full pr-10"
                  />

                  <button
                    type="button"
                    onClick={() =>
                      setShowPassword(
                        !showPassword
                      )
                    }
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-700"
                    disabled={
                      loading ||
                      authLoading
                    }
                  >
                    {showPassword ? (
                      <EyeOff className="h-4 w-4" />
                    ) : (
                      <Eye className="h-4 w-4" />
                    )}
                  </button>
                </div>
              </div>

              <div className="flex justify-center pt-2">
                <Turnstile
                  ref={loginCaptchaRef}
                  siteKey={
                    import.meta.env
                      .VITE_TURNSTILE_SITE_KEY
                  }
                  onSuccess={(token) => {
                    setCaptchaToken(token);
                    setError(null);
                  }}
                  onExpire={() => {
                    setCaptchaToken(null);
                  }}
                  onError={() => {
                    setCaptchaToken(null);

                    setError(
                      "No se ha podido verificar el CAPTCHA. Inténtalo de nuevo."
                    );
                  }}
                />
              </div>

              <Button
                type="submit"
                className="w-full bg-[#1E3A8A] hover:bg-[#1E3A8A]/90 text-white font-semibold py-2"
                disabled={
                  loading ||
                  authLoading
                }
              >
                {loading ||
                authLoading
                  ? "Iniciando sesión..."
                  : "Iniciar sesión"}
              </Button>

              <div className="text-center space-y-2 pt-4">
                <button
                  type="button"
                  onClick={() => {
                    setMode(
                      "forgot-password"
                    );
                    setCaptchaToken(null);
                  }}
                  className="text-sm text-[#1E3A8A] hover:underline"
                  disabled={
                    loading ||
                    authLoading
                  }
                >
                  ¿Has olvidado tu contraseña?
                </button>

                <p className="text-sm text-gray-600">
                  ¿No tienes cuenta?{" "}
                  <button
                    type="button"
                    onClick={() => {
                      setMode("register");
                      setCaptchaToken(null);
                      setError(null);
                      setSuccess(null);
                    }}
                    className="text-[#1E3A8A] hover:underline font-semibold"
                    disabled={
                      loading ||
                      authLoading
                    }
                  >
                    Regístrate
                  </button>
                </p>
              </div>
            </form>
          )}

          {mode === "register" && (
            <form
              onSubmit={handleRegister}
              className="space-y-4"
            >
              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Nombre y apellidos
                </label>

                <Input
                  type="text"
                  placeholder="Juan Pérez"
                  value={
                    registerForm.nombre
                  }
                  onChange={(e) =>
                    setRegisterForm({
                      ...registerForm,
                      nombre:
                        e.target.value,
                    })
                  }
                  required
                  disabled={
                    loading ||
                    authLoading
                  }
                  className="w-full"
                />
              </div>

              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Empresa (opcional)
                </label>

                <Input
                  type="text"
                  placeholder="Mi Empresa S.L."
                  value={
                    registerForm.empresa
                  }
                  onChange={(e) =>
                    setRegisterForm({
                      ...registerForm,
                      empresa:
                        e.target.value,
                    })
                  }
                  disabled={
                    loading ||
                    authLoading
                  }
                  className="w-full"
                />
              </div>

              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Correo electrónico
                </label>

                <Input
                  type="email"
                  placeholder="tu@email.com"
                  value={
                    registerForm.email
                  }
                  onChange={(e) =>
                    setRegisterForm({
                      ...registerForm,
                      email:
                        e.target.value,
                    })
                  }
                  required
                  disabled={
                    loading ||
                    authLoading
                  }
                  className="w-full"
                />
              </div>

              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Contraseña
                </label>

                <div className="relative">
                  <Input
                    type={
                      showPassword
                        ? "text"
                        : "password"
                    }
                    placeholder="••••••••"
                    value={
                      registerForm.password
                    }
                    onChange={(e) =>
                      setRegisterForm({
                        ...registerForm,
                        password:
                          e.target.value,
                      })
                    }
                    required
                    disabled={
                      loading ||
                      authLoading
                    }
                    className="w-full pr-10"
                  />

                  <button
                    type="button"
                    onClick={() =>
                      setShowPassword(
                        !showPassword
                      )
                    }
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-700"
                    disabled={
                      loading ||
                      authLoading
                    }
                  >
                    {showPassword ? (
                      <EyeOff className="h-4 w-4" />
                    ) : (
                      <Eye className="h-4 w-4" />
                    )}
                  </button>
                </div>

                <PasswordStrengthIndicator
                  password={
                    registerForm.password
                  }
                />
              </div>

              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Confirmar contraseña
                </label>

                <div className="relative">
                  <Input
                    type={
                      showConfirmPassword
                        ? "text"
                        : "password"
                    }
                    placeholder="••••••••"
                    value={
                      registerForm.confirmPassword
                    }
                    onChange={(e) =>
                      setRegisterForm({
                        ...registerForm,
                        confirmPassword:
                          e.target.value,
                      })
                    }
                    required
                    disabled={
                      loading ||
                      authLoading
                    }
                    className="w-full pr-10"
                  />

                  <button
                    type="button"
                    onClick={() =>
                      setShowConfirmPassword(
                        !showConfirmPassword
                      )
                    }
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-700"
                    disabled={
                      loading ||
                      authLoading
                    }
                  >
                    {showConfirmPassword ? (
                      <EyeOff className="h-4 w-4" />
                    ) : (
                      <Eye className="h-4 w-4" />
                    )}
                  </button>
                </div>
              </div>

              <div className="rounded-lg border border-gray-200 bg-gray-50 p-4 space-y-3">
                <p className="text-sm font-semibold text-gray-800">
                  Información legal
                </p>

                <label className="flex items-start gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={
                      legalAccepted.terms
                    }
                    onChange={(e) =>
                      setLegalAccepted({
                        ...legalAccepted,
                        terms:
                          e.target.checked,
                      })
                    }
                    disabled={
                      loading ||
                      authLoading
                    }
                    className="mt-1 h-4 w-4 shrink-0"
                  />

                  <span className="text-sm text-gray-700">
  He leído y acepto los{" "}
  <a
    href="/terminos"
    onClick={() => {
      sessionStorage.setItem(
        "modira_previous_page",
        JSON.stringify({
          url: window.location.href,
          scrollY: window.scrollY,
        })
      );
    }}
    className="font-semibold text-[#1E3A8A] hover:underline"
  >
    Términos y Condiciones de Uso de MODIRA
  </a>
  .
</span>
                </label>

                <label className="flex items-start gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={
                      legalAccepted.privacy
                    }
                    onChange={(e) =>
                      setLegalAccepted({
                        ...legalAccepted,
                        privacy:
                          e.target.checked,
                      })
                    }
                    disabled={
                      loading ||
                      authLoading
                    }
                    className="mt-1 h-4 w-4 shrink-0"
                  />

                  <span className="text-sm text-gray-700">
  He leído la{" "}
  <a
    href="/politica-privacidad"
    onClick={() => {
      sessionStorage.setItem(
        "modira_previous_page",
        JSON.stringify({
          url: window.location.href,
          scrollY: window.scrollY,
        })
      );
    }}
    className="font-semibold text-[#1E3A8A] hover:underline"
  >
    Información de Privacidad
  </a>{" "}
  y he sido informado/a sobre el tratamiento de mis datos personales.
</span>
                </label>

                <p className="text-xs text-[#8B1E3F]">
  Ambos campos son obligatorios.
</p>
              </div>
<div className="flex justify-center pt-2">
  <Turnstile
    siteKey={
      import.meta.env
        .VITE_TURNSTILE_SITE_KEY
    }
    onSuccess={(token) => {
      setCaptchaToken(token);
      setError(null);
    }}
    onExpire={() => {
      setCaptchaToken(null);
    }}
    onError={() => {
      setCaptchaToken(null);

      setError(
        "No se ha podido verificar el CAPTCHA. Inténtalo de nuevo."
      );
    }}
  />
</div>
              <Button
                type="submit"
                className="w-full bg-[#1E3A8A] hover:bg-[#1E3A8A]/90 text-white font-semibold py-2"
                disabled={
                  loading ||
                  authLoading ||
                  !legalComplete
                }
              >
                {loading ||
                authLoading
                  ? "Registrando..."
                  : "Registrarse"}
              </Button>

              <p className="text-center text-sm text-gray-600 pt-4">
                ¿Ya tienes cuenta?{" "}
                <button
                  type="button"
                  onClick={() => {
                    setMode("login");
                    setCaptchaToken(null);
                    setError(null);
                    setSuccess(null);
                  }}
                  className="text-[#1E3A8A] hover:underline font-semibold"
                  disabled={
                    loading ||
                    authLoading
                  }
                >
                  Inicia sesión
                </button>
              </p>
            </form>
          )}

          {mode === "complete-legal" && (
            <form
              onSubmit={handleCompleteLegal}
              className="space-y-4"
            >
              <p className="text-sm text-gray-600">
                Has confirmado tu correo electrónico. Para activar tu cuenta debes completar los requisitos legales.
              </p>

              <div className="rounded-lg border border-gray-200 bg-gray-50 p-4 space-y-3">
                <label className="flex items-start gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={
                      legalAccepted.terms
                    }
                    onChange={(e) =>
                      setLegalAccepted({
                        ...legalAccepted,
                        terms:
                          e.target.checked,
                      })
                    }
                    disabled={
                      loading ||
                      authLoading
                    }
                    className="mt-1 h-4 w-4"
                  />

                  <span className="text-sm text-gray-700">
  He leído y acepto los{" "}
  <a
    href="/terminos"
    onClick={() => {
      sessionStorage.setItem(
        "modira_previous_page",
        JSON.stringify({
          url: window.location.href,
          scrollY: window.scrollY,
        })
      );
    }}
    className="font-semibold text-[#1E3A8A] hover:underline"
  >
    Términos y Condiciones de Uso de MODIRA
  </a>
  .
</span>
                </label>

                <label className="flex items-start gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={
                      legalAccepted.privacy
                    }
                    onChange={(e) =>
                      setLegalAccepted({
                        ...legalAccepted,
                        privacy:
                          e.target.checked,
                      })
                    }
                    disabled={
                      loading ||
                      authLoading
                    }
                    className="mt-1 h-4 w-4"
                  />

                  <span className="text-sm text-gray-700">
  He leído la{" "}
  <a
    href="/politica-privacidad"
    onClick={() => {
      sessionStorage.setItem(
        "modira_previous_page",
        JSON.stringify({
          url: window.location.href,
          scrollY: window.scrollY,
        })
      );
    }}
    className="font-semibold text-[#1E3A8A] hover:underline"
  >
    Información de Privacidad
  </a>{" "}
  y he sido informado/a sobre el tratamiento de mis datos personales.
</span>
                </label>
              </div>

              <Button
                type="submit"
                className="w-full bg-[#1E3A8A] hover:bg-[#1E3A8A]/90 text-white font-semibold py-2"
                disabled={
                  loading ||
                  authLoading ||
                  !legalComplete
                }
              >
                {loading ||
                authLoading
                  ? "Activando cuenta..."
                  : "Completar registro"}
              </Button>

              <p className="text-xs text-gray-500 text-center">
                Al completar este paso se registrarán en MODIRA las versiones vigentes de los documentos legales correspondientes.
              </p>
            </form>
          )}

          {mode === "forgot-password" && (
            <form
              onSubmit={handleForgotPassword}
              className="space-y-4"
            >
              <div>
                <label className="block text-sm font-semibold text-gray-700 mb-2">
                  Correo electrónico
                </label>

                <Input
                  type="email"
                  placeholder="tu@email.com"
                  value={
                    forgotForm.email
                  }
                  onChange={(e) =>
                    setForgotForm({
                      email:
                        e.target.value,
                    })
                  }
                  required
                  disabled={
                    loading ||
                    authLoading
                  }
                  className="w-full"
                />
              </div>

              <div className="flex justify-center pt-2">
                <Turnstile
                  siteKey={
                    import.meta.env
                      .VITE_TURNSTILE_SITE_KEY
                  }
                  onSuccess={(token) => {
                    setCaptchaToken(token);
                    setError(null);
                  }}
                  onExpire={() => {
                    setCaptchaToken(null);
                  }}
                  onError={() => {
                    setCaptchaToken(null);

                    setError(
                      "No se ha podido verificar el CAPTCHA. Inténtalo de nuevo."
                    );
                  }}
                />
              </div>

              <Button
                type="submit"
                className="w-full bg-[#1E3A8A] hover:bg-[#1E3A8A]/90 text-white font-semibold py-2"
                disabled={
                  loading ||
                  authLoading
                }
              >
                {loading ||
                authLoading
                  ? "Enviando..."
                  : "Enviar enlace de recuperación"}
              </Button>

              <p className="text-center text-sm text-gray-600 pt-4">
                <button
                  type="button"
                  onClick={() => {
                    setMode("login");
                    setCaptchaToken(null);
                  }}
                  className="text-[#1E3A8A] hover:underline font-semibold"
                  disabled={
                    loading ||
                    authLoading
                  }
                >
                  Volver al login
                </button>
              </p>
            </form>
          )}
        </div>
      </Card>
    </div>
  );
}