-- Fix `permission denied for table questions` when loading the published-question RPC.
-- RLS continues to limit members to published questions allowed by their plan.
grant select (is_published) on public.questions to authenticated;
