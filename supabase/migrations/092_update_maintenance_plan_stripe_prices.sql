-- ============================================================
-- 092_update_maintenance_plan_stripe_prices.sql
-- Actualiza los Stripe Price IDs de los planes de mantenimiento
-- a precios recurrentes con IVA incluido.
-- ============================================================

BEGIN;

UPDATE public.maintenance_plans
SET
    stripe_price_id = CASE code
        WHEN 'essential' THEN 'price_1ULIzqLxsioWVxfGtyi8zSEj'
        WHEN 'growth' THEN 'price_1ULIzrLxsioWVxfGLOgo7ftI'
        WHEN 'business' THEN 'price_1ULIzrLxsioWVxfG8tpEP30G'
        ELSE stripe_price_id
    END,
    updated_at = NOW()
WHERE code IN ('essential', 'growth', 'business');

-- Comprobación de seguridad: deben existir exactamente
-- los tres Price IDs nuevos después del UPDATE.
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM public.maintenance_plans
    WHERE code IN ('essential', 'growth', 'business')
      AND stripe_price_id IN (
          'price_1ULIzqLxsioWVxfGtyi8zSEj',
          'price_1ULIzrLxsioWVxfGLOgo7ftI',
          'price_1ULIzrLxsioWVxfG8tpEP30G'
      );

    IF v_count <> 3 THEN
        RAISE EXCEPTION
            'La actualización de Stripe Price IDs no se completó correctamente. Se esperaban 3 planes actualizados y se encontraron %.',
            v_count;
    END IF;
END $$;

COMMIT;