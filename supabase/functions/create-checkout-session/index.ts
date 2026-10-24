import { createClient } from "npm:@supabase/supabase-js@2";

const SITE_URL = "https://athiwat-electric-pro-max-pwa.github.io";
const PRICE_SATANG = 19900;
const corsHeaders = {
  "Access-Control-Allow-Origin": SITE_URL,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (request.headers.get("origin") !== SITE_URL) return json({ error: "Origin not allowed" }, 403);

  try {
    const authorization = request.headers.get("authorization") || "";
    const token = authorization.replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Authentication required" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const stripeSecret = Deno.env.get("STRIPE_SECRET_KEY");
    if (!supabaseUrl || !anonKey || !stripeSecret) {
      return json({ error: "Payment service is not configured" }, 503);
    }
    const supabase = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Invalid session" }, 401);

    const profileResponse = await fetch(
      `${supabaseUrl}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}&select=plan,pro_expires_at`,
      { headers: { apikey: anonKey, Authorization: `Bearer ${token}` } },
    );
    if (!profileResponse.ok) throw new Error("Could not read member status");
    const profiles = await profileResponse.json();
    if (!profiles?.length) throw new Error("Member profile not found");
    const current = profiles[0];
    const active = current.plan === "pro" &&
      (!current.pro_expires_at || Date.parse(current.pro_expires_at) > Date.now());
    if (active && !current.pro_expires_at) {
      return json({ error: "Lifetime Pro Max is already active" }, 409);
    }
    const form = new URLSearchParams();
    form.set("mode", "payment");
    form.set("success_url", `${SITE_URL}/?billing=success`);
    form.set("cancel_url", `${SITE_URL}/?billing=cancel`);
    form.set("client_reference_id", user.id);
    form.set("customer_email", user.email || "");
    form.set("metadata[user_id]", user.id);
    form.set("metadata[plan]", "pro_lifetime");
    form.set("payment_intent_data[metadata][user_id]", user.id);
    form.set("payment_intent_data[metadata][plan]", "pro_lifetime");
    form.set("line_items[0][price_data][currency]", "thb");
    form.set("line_items[0][price_data][unit_amount]", String(PRICE_SATANG));
    form.set("line_items[0][price_data][product_data][name]", "ATHIWAT ELECTRIC Pro Max · ตลอดชีพ");
    form.set("line_items[0][price_data][product_data][description]", "สิทธิ์สมาชิก Pro Max ใช้งานตลอดชีพ");
    form.set("line_items[0][quantity]", "1");
    // Thailand Stripe accounts support card and PromptPay for THB one-time Checkout.
    form.append("payment_method_types[]", "card");
    form.append("payment_method_types[]", "promptpay");
    form.set("locale", "th");
    if (active) form.set("metadata[upgrade_to_lifetime]", "true");

    const stripeResponse = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${stripeSecret}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form,
    });
    const session = await stripeResponse.json();
    if (!stripeResponse.ok) {
      console.error("Stripe Checkout session creation failed", session?.error?.type || "Stripe error");
      return json({ error: "Unable to start payment. Check Stripe payment method settings." }, 502);
    }
    return json({ url: session.url });
  } catch (error) {
    console.error("Checkout setup error", error instanceof Error ? error.message : "unknown");
    return json({ error: "Checkout could not be started" }, 500);
  }
});

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
