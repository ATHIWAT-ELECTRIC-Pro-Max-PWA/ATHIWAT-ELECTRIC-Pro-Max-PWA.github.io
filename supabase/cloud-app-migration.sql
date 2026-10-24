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
