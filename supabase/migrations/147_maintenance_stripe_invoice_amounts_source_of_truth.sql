BEGIN;

CREATE OR REPLACE FUNCTION public.calculate_maintenance_invoice_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Las facturas de Stripe conservan los importes recibidos.
  IF NEW.stripe_invoice_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Mantener el cálculo actual para las demás facturas.
  NEW.iva_porcentaje = COALESCE(NEW.iva_porcentaje, 0);

  NEW.iva_importe = CASE
    WHEN COALESCE(NEW.iva_aplicado, FALSE)
    THEN ROUND(
      COALESCE(NEW.subtotal, 0) * NEW.iva_porcentaje / 100,
      2
    )
    ELSE 0
  END;

  NEW.irpf_porcentaje = COALESCE(NEW.irpf_porcentaje, 0);

  NEW.irpf_importe = CASE
    WHEN COALESCE(NEW.irpf_aplicado, FALSE)
    THEN ROUND(
      COALESCE(NEW.subtotal, 0) * NEW.irpf_porcentaje / 100,
      2
    )
    ELSE 0
  END;

  NEW.monto = ROUND(
    COALESCE(NEW.subtotal, 0) + COALESCE(NEW.iva_importe, 0),
    2
  );

  NEW.importe_a_pagar = ROUND(
    NEW.monto - COALESCE(NEW.irpf_importe, 0),
    2
  );

  RETURN NEW;
END;
$$;

COMMIT;