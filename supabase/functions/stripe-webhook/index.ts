const EXPECTED_AMOUNT = 19900;
const SIGNATURE_TOLERANCE_SECONDS = 300;

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  try {
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const expectLive = Deno.env.get("STRIPE_EXPECT_LIVE") === "true";
    if (!webhookSecret || !supabaseUrl || !serviceRoleKey || !expectLive) {
      return new Response("Webhook is not configured for live payments", { status: 503 });
    }

    const rawBody = await request.text();
    const signature = request.headers.get("stripe-signature") || "";
    if (!await verifyStripeSignature(rawBody, signature, webhookSecret)) {
      return new Response("Invalid signature", { status: 400 });
    }
    const event = JSON.parse(rawBody);
    if (!event.livemode) return new Response("Test-mode event rejected", { status: 400 });
    if (![
      "checkout.session.completed",
      "checkout.session.async_payment_succeeded",
    ].includes(event.type)) return new Response(JSON.stringify({ received: true }), { status: 200 });

    const session = event.data?.object;
    if (
      session?.mode !== "payment" || session?.payment_status !== "paid" ||
      session?.currency !== "thb" || session?.amount_total !== EXPECTED_AMOUNT ||
      session?.metadata?.plan !== "pro_lifetime"
    ) return new Response("Payment does not match the Pro Max lifetime plan", { status: 400 });

    const userId = session?.metadata?.user_id;
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId || "")) {
      return new Response("Invalid member identity", { status: 400 });
    }
    const fulfillment = await fetch(`${supabaseUrl}/rest/v1/rpc/activate_pro_from_payment`, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_user_id: userId,
        p_stripe_session_id: session.id,
        p_stripe_payment_intent_id: session.payment_intent || null,
        p_amount_paid: session.amount_total,
        p_currency: session.currency,
      }),
    });
    if (!fulfillment.ok) {
      console.error("Payment fulfillment failed", fulfillment.status);
      return new Response("Payment fulfillment failed", { status: 500 });
    }
    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("Stripe webhook error", error instanceof Error ? error.message : "unknown");
    return new Response("Webhook processing error", { status: 500 });
  }
});

async function verifyStripeSignature(body: string, header: string, secret: string) {
  const parts = header.split(",").map((part) => part.split("=", 2));
  const timestamp = parts.find(([key]) => key === "t")?.[1];
  const signatures = parts.filter(([key]) => key === "v1").map(([, value]) => value);
  if (!timestamp || signatures.length === 0) return false;
  const timestampNumber = Number(timestamp);
  if (!Number.isFinite(timestampNumber) || Math.abs(Date.now() / 1000 - timestampNumber) > SIGNATURE_TOLERANCE_SECONDS) {
    return false;
  }
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${body}`)));
  const expected = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return signatures.some((signature) => constantTimeEqual(signature, expected));
}

function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}
