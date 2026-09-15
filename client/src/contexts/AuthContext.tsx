import React, {
  createContext,
  useContext,
  useEffect,
  useState,
} from "react";
import {
  User,
  Session,
} from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";

interface AuthContextType {
  user: User | null;
  session: Session | null;
  loading: boolean;
  isRecoverySession: boolean;

  signUp: (
    email: string,
    password: string,
    nombre: string,
    empresa?: string,
    captchaToken?: string
  ) => Promise<{
    success: boolean;
    error?: string;
  }>;

  completeRegistrationLegalRequirements: (
  termsAccepted: boolean,
  privacyAcknowledged: boolean
) => Promise<{
  success: boolean;
  error?: string;
}>;

  getRegistrationStatus: () => Promise<{
    success: boolean;
    status?: string;
    error?: string;
  }>;

  signIn: (
    email: string,
    password: string,
    captchaToken?: string
  ) => Promise<{
    success: boolean;
    error?: string;
  }>;

  signOut: () => Promise<{
    success: boolean;
    error?: string;
  }>;

  resetPassword: (
    email: string,
    captchaToken?: string
  ) => Promise<{
    success: boolean;
    error?: string;
  }>;

  updatePassword: (
    newPassword: string
  ) => Promise<{
    success: boolean;
    error?: string;
  }>;
}

export const AuthContext =
  createContext<AuthContextType | undefined>(
    undefined
  );

export function AuthProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const [user, setUser] =
    useState<User | null>(null);

  const [session, setSession] =
    useState<Session | null>(null);

  const [loading, setLoading] =
    useState(true);

  const [isRecoverySession, setIsRecoverySession] =
    useState(false);

  useEffect(() => {
    const initializeAuth = async () => {
      try {
        const {
          data: { session },
        } = await supabase.auth.getSession();

        setSession(session);
        setUser(session?.user ?? null);
      } catch (error) {
        console.error(
          "[Auth] Error initializing auth:",
          error
        );
      } finally {
        setLoading(false);
      }
    };

    initializeAuth();

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(
      (event, session) => {
        setSession(session);
        setUser(session?.user ?? null);

        if (event === "PASSWORD_RECOVERY") {
          setIsRecoverySession(true);
        }
      }
    );

    return () => {
      subscription?.unsubscribe();
    };
  }, []);

  const signUp = async (
    email: string,
    password: string,
    nombre: string,
    empresa?: string,
    captchaToken?: string
  ): Promise<{
    success: boolean;
    error?: string;
  }> => {
    try {
      const { data, error } =
  await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: `${window.location.origin}/auth`,
      data: {
        nombre,
        empresa: empresa || null,
      },
      captchaToken,
    },
  });

      if (error) {
        return {
          success: false,
          error: error.message,
        };
      }

      if (!data.user) {
        return {
          success: false,
          error: "Error creating user",
        };
      }

      return {
        success: true,
      };
    } catch (error) {
      console.error(
        "[Auth] Sign up error:",
        error
      );

      return {
        success: false,
        error: "Error during sign up",
      };
    }
  };

  /*
   * Completa los requisitos legales del registro.
   *
   * Esta RPC debe ejecutarse DESPUÉS de confirmar el correo
   * y disponer de una sesión autenticada.
   *
   * La BD obtiene las versiones vigentes de los documentos y
   * registra los eventos legales. El frontend no envía
   * document_id, versión, hash, IP ni user-agent.
   */
  const completeRegistrationLegalRequirements = async (
  termsAccepted: boolean,
  privacyAcknowledged: boolean
): Promise<{
    success: boolean;
    error?: string;
  }> => {
    try {
      const {
        data: { session: currentSession },
      } = await supabase.auth.getSession();

      if (!currentSession) {
        return {
          success: false,
          error:
            "Debes confirmar tu correo electrónico e iniciar sesión antes de completar el registro.",
        };
      }

      const { error } = await supabase.rpc(
  "complete_registration_legal_requirements",
  {
    p_terms_accepted: true,
    p_privacy_acknowledged: true,
  }
);

      if (error) {
        return {
          success: false,
          error: error.message,
        };
      }

      return {
        success: true,
      };
    } catch (error) {
      console.error(
        "[Auth] Error completing legal registration:",
        error
      );

      return {
        success: false,
        error:
          "No se han podido completar los requisitos legales del registro.",
      };
    }
  };

  /*
   * Consulta únicamente el estado legal de la cuenta.
   *
   * Se utiliza después del login porque un usuario con
   * pending_legal no puede depender de la lectura directa
   * de profiles.
   */
  const getRegistrationStatus = async (): Promise<{
    success: boolean;
    status?: string;
    error?: string;
  }> => {
    try {
      const {
        data: { session: currentSession },
      } = await supabase.auth.getSession();

      if (!currentSession) {
        return {
          success: false,
          error: "No hay una sesión activa.",
        };
      }

      const { data, error } =
        await supabase.rpc(
          "get_current_registration_status"
        );

      if (error) {
        return {
          success: false,
          error: error.message,
        };
      }

      return {
        success: true,
        status: data,
      };
    } catch (error) {
      console.error(
        "[Auth] Error getting registration status:",
        error
      );

      return {
        success: false,
        error:
          "No se ha podido comprobar el estado del registro.",
      };
    }
  };

  const signIn = async (
    email: string,
    password: string,
    captchaToken?: string
  ): Promise<{
    success: boolean;
    error?: string;
  }> => {
    try {
      const { error } =
        await supabase.auth.signInWithPassword({
          email,
          password,
          options: {
            captchaToken,
          },
        });

      if (error) {
        return {
          success: false,
          error: error.message,
        };
      }

      return {
        success: true,
      };
    } catch (error) {
      console.error(
        "[Auth] Sign in error:",
        error
      );

      return {
        success: false,
        error: "Error during sign in",
      };
    }
  };

  const signOut = async (): Promise<{
    success: boolean;
    error?: string;
  }> => {
    try {
      const { error } =
        await supabase.auth.signOut();

      if (error) {
        return {
          success: false,
          error: error.message,
        };
      }

      return {
        success: true,
      };
    } catch (error) {
      console.error(
        "[Auth] Sign out error:",
        error
      );

      return {
        success: false,
        error: "Error during sign out",
      };
    }
  };

  const resetPassword = async (
    email: string,
    captchaToken?: string
  ): Promise<{
    success: boolean;
    error?: string;
  }> => {
    try {
      const { error } =
        await supabase.auth.resetPasswordForEmail(
          email,
          {
            redirectTo:
              `${window.location.origin}/auth/reset-password`,
            captchaToken,
          }
        );

      if (error) {
        return {
          success: false,
          error: error.message,
        };
      }

      return {
        success: true,
      };
    } catch (error) {
      console.error(
        "[Auth] Reset password error:",
        error
      );

      return {
        success: false,
        error:
          "Error requesting password reset",
      };
    }
  };

  const updatePassword = async (
    newPassword: string
  ): Promise<{
    success: boolean;
    error?: string;
  }> => {
    try {
      const { error } =
        await supabase.auth.updateUser({
          password: newPassword,
        });

      if (error) {
        return {
          success: false,
          error: error.message,
        };
      }

      return {
        success: true,
      };
    } catch (error) {
      console.error(
        "[Auth] Update password error:",
        error
      );

      return {
        success: false,
        error: "Error updating password",
      };
    }
  };

  return (
    <AuthContext.Provider
      value={{
        user,
        session,
        loading,
        isRecoverySession,
        signUp,
        completeRegistrationLegalRequirements,
        getRegistrationStatus,
        signIn,
        signOut,
        resetPassword,
        updatePassword,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);

  if (!context) {
    throw new Error(
      "useAuth must be used within an AuthProvider"
    );
  }

  return context;
}
