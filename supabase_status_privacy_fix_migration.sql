-- Fix: Status privacy (Exclude / Only share) RLS + visibility policy
-- This makes exclusion/allow-lists actually enforceable for viewers.
-- Project: ljnparociyyggmxdewwv

-- ------------------------------------------------------------
-- 1) status_privacy (exclude list)
-- Allow SELECT to either side (owner or excluded user),
-- but only owner can INSERT/DELETE.
-- ------------------------------------------------------------
alter table public.status_privacy enable row level security;

drop policy if exists "Users can manage own status privacy" on public.status_privacy;
drop policy if exists "Users can select status privacy" on public.status_privacy;
drop policy if exists "Users can insert status privacy" on public.status_privacy;
drop policy if exists "Users can delete status privacy" on public.status_privacy;

create policy "Users can select status privacy" on public.status_privacy
for select to authenticated
using (auth.uid() = user_id or auth.uid() = excluded_user_id);

create policy "Users can insert status privacy" on public.status_privacy
for insert to authenticated
with check (auth.uid() = user_id);

create policy "Users can delete status privacy" on public.status_privacy
for delete to authenticated
using (auth.uid() = user_id);

-- ------------------------------------------------------------
-- 2) status_privacy_allowed (only-share-with list)
-- Allow SELECT to either side (owner or allowed user),
-- but only owner can INSERT/DELETE.
-- ------------------------------------------------------------
alter table public.status_privacy_allowed enable row level security;

drop policy if exists "Users can manage own status privacy allowed" on public.status_privacy_allowed;
drop policy if exists "Users can select status privacy allowed" on public.status_privacy_allowed;
drop policy if exists "Users can insert status privacy allowed" on public.status_privacy_allowed;
drop policy if exists "Users can delete status privacy allowed" on public.status_privacy_allowed;

create policy "Users can select status privacy allowed" on public.status_privacy_allowed
for select to authenticated
using (auth.uid() = user_id or auth.uid() = allowed_user_id);

create policy "Users can insert status privacy allowed" on public.status_privacy_allowed
for insert to authenticated
with check (auth.uid() = user_id);

create policy "Users can delete status privacy allowed" on public.status_privacy_allowed
for delete to authenticated
using (auth.uid() = user_id);

-- ------------------------------------------------------------
-- 3) Update status SELECT policy to enforce status_privacy_mode
--   - all/exclude: everyone except excluded list
--   - only: only allow-list
-- ------------------------------------------------------------
drop policy if exists "Users can view status" on public.status;

create policy "Users can view status" on public.status
for select to authenticated
using (
  -- Always can see your own
  user_id = auth.uid()

  or (
    coalesce((select p.status_privacy_mode from public.profiles p where p.id = status.user_id), 'all') in ('all', 'exclude')
    and not exists (
      select 1 from public.status_privacy sp
      where sp.user_id = status.user_id
        and sp.excluded_user_id = auth.uid()
    )
  )

  or (
    coalesce((select p.status_privacy_mode from public.profiles p where p.id = status.user_id), 'all') = 'only'
    and exists (
      select 1 from public.status_privacy_allowed sa
      where sa.user_id = status.user_id
        and sa.allowed_user_id = auth.uid()
    )
  )
);

-- Realtime (optional, but helps keep UI consistent)
alter publication supabase_realtime add table public.status_privacy;
alter publication supabase_realtime add table public.status_privacy_allowed;
