-- Starter schema for ATHIWAT ELECTRIC Pro Max.
-- Run this in the Supabase SQL Editor for a new project.
-- Never put a service_role key in the browser or mobile app.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  plan text not null default 'free' check (plan in ('free', 'pro')),
  pro_expires_at timestamptz,
  role text not null default 'member' check (role in ('member', 'content_admin')),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create table if not exists public.exam_criteria (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  source_url text,
  effective_on date,
  checked_at date,
  notes text,
  is_current boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  exam_type text not null check (exam_type in ('general', 'special')),
  exam_part text not null check (exam_part in ('ภาค ก', 'ภาค ข', 'ภาค ค')),
  subject text not null,
  topic text not null,
  access_tier text not null default 'basic' check (access_tier in ('basic', 'pro')),
  prompt text not null,
  choices jsonb not null check (jsonb_typeof(choices) = 'array' and jsonb_array_length(choices) = 4),
  answer_index smallint not null check (answer_index between 0 and 3),
  explanation text not null default '',
  key_point text not null default '',
  criteria_id uuid references public.exam_criteria(id) on delete set null,
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.exam_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  mode text not null check (mode in ('practice', 'mock')),
  status text not null default 'in_progress' check (status in ('in_progress', 'submitted')),
  question_ids uuid[] not null default '{}',
  score integer,
  total integer not null default 0,
  started_at timestamptz not null default now(),
  submitted_at timestamptz
);

create table if not exists public.exam_answers (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete restrict,
  topic_snapshot text not null,
  selected_index smallint check (selected_index between 0 and 3),
  is_correct boolean not null,
  answered_at timestamptz not null default now(),
  unique (attempt_id, question_id)
);

create table if not exists public.daily_usage (
  user_id uuid not null references public.profiles(id) on delete cascade,
  usage_date date not null default current_date,
  question_count integer not null default 0 check (question_count between 0 and 10),
  primary key (user_id, usage_date)
);

create table if not exists public.device_sessions (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  device_id uuid not null,
  lease_token uuid not null,
  last_seen_at timestamptz not null default now(),
  lease_expires_at timestamptz not null
);

alter table public.profiles enable row level security;
alter table public.exam_criteria enable row level security;
alter table public.questions enable row level security;
alter table public.exam_attempts enable row level security;
alter table public.exam_answers enable row level security;
alter table public.daily_usage enable row level security;
alter table public.device_sessions enable row level security;

drop policy if exists "Members read their profile" on public.profiles;
create policy "Members read their profile" on public.profiles
  for select to authenticated using (id = auth.uid());

drop policy if exists "Members read current criteria" on public.exam_criteria;
create policy "Members read current criteria" on public.exam_criteria
  for select to authenticated using (is_current);
drop policy if exists "Content admins manage criteria" on public.exam_criteria;
create policy "Content admins manage criteria" on public.exam_criteria
  for all to authenticated using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'content_admin')
  ) with check (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'content_admin')
  );

drop policy if exists "Members read questions allowed by plan" on public.questions;
create policy "Members read questions allowed by plan" on public.questions
  for select to authenticated using (
    is_published and (
      access_tier = 'basic' or exists (
        select 1 from public.profiles p where p.id = auth.uid() and p.plan = 'pro'
      )
    )
  );
drop policy if exists "Content admins manage questions" on public.questions;
create policy "Content admins manage questions" on public.questions
  for all to authenticated using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'content_admin')
  ) with check (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'content_admin')
  );

drop policy if exists "Members read their attempts" on public.exam_attempts;
create policy "Members read their attempts" on public.exam_attempts
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "Members create their attempts" on public.exam_attempts;
create policy "Members create their attempts" on public.exam_attempts
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Members update their attempts" on public.exam_attempts;
create policy "Members update their attempts" on public.exam_attempts
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "Members read their answers" on public.exam_answers;
create policy "Members read their answers" on public.exam_answers
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "Members save their answers" on public.exam_answers;
create policy "Members save their answers" on public.exam_answers
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "Members read their daily usage" on public.daily_usage;
create policy "Members read their daily usage" on public.daily_usage
  for select to authenticated using (user_id = auth.uid());

-- Expose question text and choices to members. Keep answer keys and explanations
-- out of direct table reads; serve them through a verified server function later.
revoke all on public.questions from anon, authenticated;
grant select (id, exam_type, exam_part, subject, topic, access_tier, prompt, choices, criteria_id, is_published, created_at, updated_at)
  on public.questions to authenticated;
grant insert, update, delete on public.questions to authenticated;
grant select on public.profiles, public.exam_criteria, public.exam_attempts, public.exam_answers, public.daily_usage to authenticated;

create or replace function public.reserve_free_quota(p_question_count integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_plan text;
  v_after integer;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if p_question_count < 1 or p_question_count > 10 then raise exception 'Invalid question count'; end if;
  select p.plan into v_plan from public.profiles p where p.id = v_user_id;
  if v_plan = 'pro' then return 2147483647; end if;
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

create or replace function public.claim_device_session(p_device_id uuid)
returns table (accepted boolean, lease_token uuid, lease_expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_token uuid;
  v_expires timestamptz;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  insert into public.device_sessions (user_id, device_id, lease_token, last_seen_at, lease_expires_at)
  values (v_user_id, p_device_id, gen_random_uuid(), now(), now() + interval '90 seconds')
  on conflict (user_id) do update
    set device_id = excluded.device_id,
        lease_token = gen_random_uuid(),
        last_seen_at = now(),
        lease_expires_at = now() + interval '90 seconds'
    where public.device_sessions.lease_expires_at < now()
       or public.device_sessions.device_id = excluded.device_id
  returning public.device_sessions.lease_token, public.device_sessions.lease_expires_at
    into v_token, v_expires;
  return query select v_token is not null, v_token, v_expires;
end;
$$;

create or replace function public.heartbeat_device_session(p_device_id uuid, p_lease_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then return false; end if;
  update public.device_sessions
     set last_seen_at = now(), lease_expires_at = now() + interval '90 seconds'
   where user_id = v_user_id and device_id = p_device_id and lease_token = p_lease_token;
  return found;
end;
$$;

create or replace function public.release_device_session(p_device_id uuid, p_lease_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then return false; end if;
  delete from public.device_sessions
   where user_id = v_user_id and device_id = p_device_id and lease_token = p_lease_token;
  return found;
end;
$$;

revoke all on function public.reserve_free_quota(integer) from public, anon;
revoke all on function public.claim_device_session(uuid) from public, anon;
revoke all on function public.heartbeat_device_session(uuid, uuid) from public, anon;
revoke all on function public.release_device_session(uuid, uuid) from public, anon;
grant execute on function public.reserve_free_quota(integer) to authenticated;
grant execute on function public.claim_device_session(uuid) to authenticated;
grant execute on function public.heartbeat_device_session(uuid, uuid) to authenticated;
grant execute on function public.release_device_session(uuid, uuid) to authenticated;

-- Return published question content without exposing answer keys to the browser.
create or replace function public.get_published_questions(
  p_exam_type text default null,
  p_exam_part text default null,
  p_subject text default null,
  p_topic text default null,
  p_limit integer default 200
)
returns table (
  id uuid,
  exam_type text,
  exam_part text,
  subject text,
  topic text,
  access_tier text,
  prompt text,
  choices jsonb
)
language sql
stable
security invoker
set search_path = ''
as $$
  select q.id, q.exam_type, q.exam_part, q.subject, q.topic,
         q.access_tier, q.prompt, q.choices
    from public.questions q
   where q.is_published
     and (p_exam_type is null or q.exam_type = p_exam_type)
     and (p_exam_part is null or q.exam_part = p_exam_part)
     and (p_subject is null or q.subject = p_subject)
     and (p_topic is null or q.topic = p_topic)
     and (q.access_tier = 'basic' or exists (
       select 1 from public.profiles p
        where p.id = auth.uid() and p.plan = 'pro'
     ))
   order by q.created_at desc
   limit least(greatest(coalesce(p_limit, 200), 1), 500);
$$;

-- Grade a practice answer only after the member submits a choice.
create or replace function public.check_practice_answer(
  p_question_id uuid,
  p_selected_index smallint
)
returns table (
  is_correct boolean,
  correct_index smallint,
  explanation text,
  key_point text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_plan text;
  v_answer smallint;
  v_explanation text;
  v_key_point text;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  select p.plan into v_plan from public.profiles p where p.id = v_user_id;
  if v_plan is null then v_plan := 'free'; end if;

  select q.answer_index, q.explanation, q.key_point
    into v_answer, v_explanation, v_key_point
    from public.questions q
   where q.id = p_question_id
     and q.is_published
     and (q.access_tier = 'basic' or v_plan = 'pro');
  if not found then raise exception 'Question not found or not accessible'; end if;
  if p_selected_index is null or p_selected_index < 0 or p_selected_index > 3 then
    raise exception 'Invalid answer choice';
  end if;

  return query select
    p_selected_index = v_answer,
    case when v_plan = 'pro' then v_answer else null::smallint end,
    case when v_plan = 'pro' then v_explanation else '' end,
    case when v_plan = 'pro' then v_key_point else '' end;
end;
$$;

-- Store a submitted exam and return only the detail permitted by the member's plan.
create or replace function public.submit_exam(
  p_mode text,
  p_question_ids uuid[],
  p_selected_indices smallint[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_plan text;
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

  select p.plan into v_plan from public.profiles p where p.id = v_user_id;
  if v_plan is null then v_plan := 'free'; end if;

  -- Validate the complete set before charging free members or writing an attempt.
  for i in 1..v_total loop
    if p_selected_indices[i] is not null and (p_selected_indices[i] < 0 or p_selected_indices[i] > 3) then
      raise exception 'Invalid answer choice';
    end if;
    if not exists (
      select 1 from public.questions q
       where q.id = p_question_ids[i] and q.is_published
         and (q.access_tier = 'basic' or v_plan = 'pro')
    ) then raise exception 'Question not found or not accessible'; end if;
  end loop;

  if v_plan <> 'pro' and public.reserve_free_quota(v_total) = -1 then
    raise exception 'Free daily question limit reached';
  end if;

  insert into public.exam_attempts (user_id, mode, status, question_ids, total, submitted_at)
  values (v_user_id, p_mode, 'submitted', p_question_ids, v_total, now())
  returning id into v_attempt_id;

  for i in 1..v_total loop
    select q.answer_index, q.topic, q.subject
      into v_answer, v_topic, v_subject
      from public.questions q where q.id = p_question_ids[i];
    v_is_correct := p_selected_indices[i] is not null and p_selected_indices[i] = v_answer;
    if v_is_correct then v_score := v_score + 1; end if;
    insert into public.exam_answers (
      attempt_id, user_id, question_id, topic_snapshot, selected_index, is_correct
    ) values (
      v_attempt_id, v_user_id, p_question_ids[i], v_topic, p_selected_indices[i], v_is_correct
    );
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'question_id', p_question_ids[i],
      'is_correct', v_is_correct,
      'correct_index', case when v_plan = 'pro' then v_answer else null end,
      'subject', v_subject,
      'topic', v_topic
    ));
  end loop;

  update public.exam_attempts set score = v_score where id = v_attempt_id;
  return jsonb_build_object('attempt_id', v_attempt_id, 'score', v_score, 'total', v_total, 'details', v_details);
end;
$$;

create or replace function public.get_my_topic_analytics()
returns table (topic text, total bigint, correct bigint, percent numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select a.topic_snapshot,
         count(*)::bigint,
         count(*) filter (where a.is_correct)::bigint,
         round(100.0 * count(*) filter (where a.is_correct) / nullif(count(*), 0), 1)
    from public.exam_answers a
   where a.user_id = auth.uid()
   group by a.topic_snapshot
   order by a.topic_snapshot;
$$;

revoke all on function public.get_published_questions(text, text, text, text, integer) from public, anon;
revoke all on function public.check_practice_answer(uuid, smallint) from public, anon;
revoke all on function public.submit_exam(text, uuid[], smallint[]) from public, anon;
revoke all on function public.get_my_topic_analytics() from public, anon;
grant execute on function public.get_published_questions(text, text, text, text, integer) to authenticated;
grant execute on function public.check_practice_answer(uuid, smallint) to authenticated;
grant execute on function public.submit_exam(text, uuid[], smallint[]) to authenticated;
grant execute on function public.get_my_topic_analytics() to authenticated;

-- Run once after schema.sql. The first signed-in member becomes the content admin.
create or replace function public.claim_initial_content_admin()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  perform pg_advisory_xact_lock(871234, 20261023);
  if exists (select 1 from public.profiles p where p.role = 'content_admin') then
    return false;
  end if;
  update public.profiles set role = 'content_admin' where id = auth.uid();
  return found;
end;
$$;

revoke all on function public.claim_initial_content_admin() from public, anon;
grant execute on function public.claim_initial_content_admin() to authenticated;
