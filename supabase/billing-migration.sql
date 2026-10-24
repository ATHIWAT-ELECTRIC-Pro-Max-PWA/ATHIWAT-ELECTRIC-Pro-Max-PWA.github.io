-- ATHIWAT ELECTRIC Pro Max: Stripe one-time lifetime access (THB 199)
-- Run once in Supabase SQL Editor after the existing schema.
-- Only a verified Stripe webhook using the service-role key may grant access.

alter table public.profiles
  add column if not exists pro_expires_at timestamptz;

create table if not exists public.pro_payments (
  stripe_session_id text primary key,
  stripe_payment_intent_id text,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount_paid integer not null check (amount_paid = 19900),
  currency text not null check (currency = 'thb'),
  paid_at timestamptz not null default now(),
  expires_at timestamptz
);
create unique index if not exists pro_payments_payment_intent_unique
  on public.pro_payments(stripe_payment_intent_id)
  where stripe_payment_intent_id is not null;
alter table public.pro_payments enable row level security;
revoke all on public.pro_payments from public, anon, authenticated;

-- This helper can only answer for the currently authenticated user.
create or replace function public.current_user_is_pro()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.plan = 'pro'
       and (p.pro_expires_at is null or p.pro_expires_at > now())
  );
$$;
revoke all on function public.current_user_is_pro() from public, anon;
grant execute on function public.current_user_is_pro() to authenticated;

-- Service-role-only, idempotent fulfillment function.
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
  v_current_expiry timestamptz;
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
  select p.pro_expires_at into v_current_expiry
    from public.profiles p where p.id = p_user_id for update;
  if not found then raise exception 'Member profile not found'; end if;

  -- Return an existing fulfillment on Stripe retries; never extend twice.
  select x.expires_at into v_expiry from public.pro_payments x
   where x.stripe_session_id = p_stripe_session_id;
  if found then return v_expiry; end if;

  v_expiry := null;
  insert into public.pro_payments (
    stripe_session_id, stripe_payment_intent_id, user_id,
    amount_paid, currency, expires_at
  ) values (
    p_stripe_session_id, p_stripe_payment_intent_id, p_user_id,
    p_amount_paid, lower(p_currency), v_expiry
  );
  update public.profiles
     set plan = 'pro', pro_expires_at = null
   where id = p_user_id;
  return v_expiry;
end;
$$;
revoke all on function public.activate_pro_from_payment(uuid, text, text, integer, text)
  from public, anon, authenticated;
grant execute on function public.activate_pro_from_payment(uuid, text, text, integer, text)
  to service_role;

drop policy if exists "Members read questions allowed by plan" on public.questions;
create policy "Members read questions allowed by plan" on public.questions
  for select to authenticated using (
    is_published and (access_tier = 'basic' or public.current_user_is_pro())
  );

create or replace function public.reserve_free_quota(p_question_count integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_after integer;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if p_question_count < 1 or p_question_count > 10 then raise exception 'Invalid question count'; end if;
  if public.current_user_is_pro() then return 2147483647; end if;
  insert into public.daily_usage (user_id, usage_date, question_count)
  values (v_user_id, current_date, p_question_count)
  on conflict (user_id, usage_date) do update
    set question_count = public.daily_usage.question_count + excluded.question_count
    where public.daily_usage.question_count + excluded.question_count <= 10
  returning question_count into v_after;
  if v_after is null then return -1; end if;
  return 10 - v_after;
end;
$$;

create or replace function public.get_published_questions(
  p_exam_type text default null,
  p_exam_part text default null,
  p_subject text default null,
  p_topic text default null,
  p_limit integer default 200
)
returns table (
  id uuid, exam_type text, exam_part text, subject text, topic text,
  access_tier text, prompt text, choices jsonb
)
language sql stable security invoker set search_path = ''
as $$
  select q.id, q.exam_type, q.exam_part, q.subject, q.topic,
         q.access_tier, q.prompt, q.choices
    from public.questions q
   where q.is_published
     and (p_exam_type is null or q.exam_type = p_exam_type)
     and (p_exam_part is null or q.exam_part = p_exam_part)
     and (p_subject is null or q.subject = p_subject)
     and (p_topic is null or q.topic = p_topic)
     and (q.access_tier = 'basic' or public.current_user_is_pro())
   order by q.created_at desc
   limit least(greatest(coalesce(p_limit, 200), 1), 500);
$$;

create or replace function public.check_practice_answer(
  p_question_id uuid,
  p_selected_index smallint
)
returns table (is_correct boolean, correct_index smallint, explanation text, key_point text)
language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_is_pro boolean;
  v_answer smallint;
  v_explanation text;
  v_key_point text;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  v_is_pro := public.current_user_is_pro();
  select q.answer_index, q.explanation, q.key_point
    into v_answer, v_explanation, v_key_point
    from public.questions q
   where q.id = p_question_id and q.is_published
     and (q.access_tier = 'basic' or v_is_pro);
  if not found then raise exception 'Question not found or not accessible'; end if;
  if p_selected_index is null or p_selected_index < 0 or p_selected_index > 3 then
    raise exception 'Invalid answer choice';
  end if;
  return query select p_selected_index = v_answer,
    case when v_is_pro then v_answer else null::smallint end,
    case when v_is_pro then v_explanation else '' end,
    case when v_is_pro then v_key_point else '' end;
end;
$$;

create or replace function public.submit_exam(
  p_mode text,
  p_question_ids uuid[],
  p_selected_indices smallint[]
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_is_pro boolean;
  v_total integer;
  v_score integer := 0;
  v_attempt_id uuid;
  v_answer smallint;
  v_topic text;
  v_subject text;
  v_is_correct boolean;
  v_details jsonb := '[]'::jsonb;
  i integer;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if p_mode is null or p_mode not in ('practice', 'mock') then raise exception 'Invalid exam mode'; end if;
  v_total := coalesce(array_length(p_question_ids, 1), 0);
  if v_total < 1 or v_total > 100 or coalesce(array_length(p_selected_indices, 1), 0) <> v_total then
    raise exception 'Invalid exam submission';
  end if;
  if (select count(distinct u.question_id) from unnest(p_question_ids) as u(question_id)) <> v_total then
    raise exception 'Duplicate question in exam';
  end if;
  v_is_pro := public.current_user_is_pro();

  for i in 1..v_total loop
    if p_selected_indices[i] is not null and (p_selected_indices[i] < 0 or p_selected_indices[i] > 3) then
      raise exception 'Invalid answer choice';
    end if;
    if not exists (
      select 1 from public.questions q where q.id = p_question_ids[i] and q.is_published
        and (q.access_tier = 'basic' or v_is_pro)
    ) then raise exception 'Question not found or not accessible'; end if;
  end loop;
  if not v_is_pro and public.reserve_free_quota(v_total) = -1 then
    raise exception 'Free daily question limit reached';
  end if;

  insert into public.exam_attempts (user_id, mode, status, question_ids, total, submitted_at)
  values (v_user_id, p_mode, 'submitted', p_question_ids, v_total, now())
  returning id into v_attempt_id;
  for i in 1..v_total loop
    select q.answer_index, q.topic, q.subject into v_answer, v_topic, v_subject
      from public.questions q where q.id = p_question_ids[i];
    v_is_correct := p_selected_indices[i] is not null and p_selected_indices[i] = v_answer;
    if v_is_correct then v_score := v_score + 1; end if;
    insert into public.exam_answers (
      attempt_id, user_id, question_id, topic_snapshot, selected_index, is_correct
    ) values (
      v_attempt_id, v_user_id, p_question_ids[i], v_topic, p_selected_indices[i], v_is_correct
    );
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'question_id', p_question_ids[i], 'is_correct', v_is_correct,
      'correct_index', case when v_is_pro then v_answer else null end,
      'subject', v_subject, 'topic', v_topic
    ));
  end loop;
  update public.exam_attempts set score = v_score where id = v_attempt_id;
  return jsonb_build_object(
    'attempt_id', v_attempt_id, 'score', v_score, 'total', v_total, 'details', v_details
  );
end;
$$;

-- Keep the existing RPC access model; only payment fulfillment is service-role-only.
