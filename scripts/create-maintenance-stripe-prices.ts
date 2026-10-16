import "dotenv/config";
import Stripe from "stripe";

const stripeSecretKey = process.env.STRIPE_SECRET_KEY;

if (!stripeSecretKey) {
  throw new Error("Falta STRIPE_SECRET_KEY en el archivo .env");
}

const stripe = new Stripe(stripeSecretKey);

const plans = [
  {
    name: "Essential",
    product: "prod_VK8stwHLMq2upa",
    amount: 14900,
  },
  {
    name: "Growth",
    product: "prod_VKcUEqmycitxGZ",
    amount: 29900,
  },
  {
    name: "Business",
    product: "prod_VKcVEAqJCKjcfF",
    amount: 49900,
  },
];

async function main() {
  for (const plan of plans) {
    const price = await stripe.prices.create({
      product: plan.product,
      currency: "eur",
      unit_amount: plan.amount,
      recurring: {
        interval: "month",
      },
      tax_behavior: "inclusive",
      metadata: {
        modira_maintenance_plan: plan.name.toLowerCase(),
        modira_tax_pricing: "inclusive",
      },
    });

    console.log("--------------------------------");
    console.log(`Plan: ${plan.name}`);
    console.log(`Price ID: ${price.id}`);
    console.log(`Importe: ${price.unit_amount} céntimos`);
    console.log(`Tax behavior: ${price.tax_behavior}`);
  }
}

main().catch((error) => {
  console.error("Error creando los Prices:", error);
  process.exit(1);
});