-- ATHIWAT ELECTRIC Pro Max: one-time lifetime access (THB 199)
-- Run once in Supabase SQL Editor after billing-migration.sql.
-- Retains historical annual-payment rows, but only verified THB 199 payments
-- grant the new lifetime entitlement.

begin;

alter table public.pro_payments
  alter column expires_at drop not null;

alter table public.pro_payments
  drop constraint if exists pro_payments_amount_paid_check;
alter table public.pro_payments
  add constraint pro_payments_amount_paid_check check (amount_paid in (9900, 19900));

create or replace function public.activate_pro_from_payment(
  p_user_id uuid,
  p_stripe_session_id text,
  p_stripe_payment_intent_id text,
  p_amount_paid integer,
  p_currency text
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expiry timestamptz;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_user_id is null or p_stripe_session_id is null or p_stripe_session_id = '' then
    raise exception 'Missing payment identity';
  end if;
  if p_amount_paid <> 19900 or lower(coalesce(p_currency, '')) <> 'thb' then
    raise exception 'Unexpected payment amount or currency';
  end if;

  perform 1 from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'Member profile not found'; end if;

  -- Stripe may retry a webhook. Never create a second fulfillment for it.
  select x.expires_at into v_expiry from public.pro_payments x
   where x.stripe_session_id = p_stripe_session_id
      or (p_stripe_payment_intent_id is not null
          and x.stripe_payment_intent_id = p_stripe_payment_intent_id);
  if found then return v_expiry; end if;

  insert into public.pro_payments (
    stripe_session_id, stripe_payment_intent_id, user_id,
    amount_paid, currency, expires_at
  ) values (
    p_stripe_session_id, p_stripe_payment_intent_id, p_user_id,
    p_amount_paid, lower(p_currency), null
  );
  update public.profiles
     set plan = 'pro', pro_expires_at = null
   where id = p_user_id;
  return null;
end;
$$;
revoke all on function public.activate_pro_from_payment(uuid, text, text, integer, text)
  from public, anon, authenticated;
grant execute on function public.activate_pro_from_payment(uuid, text, text, integer, text)
  to service_role;

commit;
