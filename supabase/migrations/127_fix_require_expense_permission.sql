-- ============================================================
-- 127_fix_require_expense_permission.sql
-- Fix: require_expense_permission used a non-existent
-- current_user_has_permission() function.
-- ============================================================

CREATE OR REPLACE FUNCTION public.require_expense_permission(
    p_permission text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION
      'Usuario no autenticado';
  END IF;


  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Solo los trabajadores pueden gestionar gastos internos';
  END IF;


  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION
      'El trabajador no está activo';
  END IF;


  IF p_permission IS NULL
     OR BTRIM(p_permission) = '' THEN
    RAISE EXCEPTION
      'Permiso requerido no especificado';
  END IF;


  IF NOT public.current_worker_has_permission(p_permission) THEN
    RAISE EXCEPTION
      'No tienes permiso para realizar esta operación';
  END IF;

END;
$function$;