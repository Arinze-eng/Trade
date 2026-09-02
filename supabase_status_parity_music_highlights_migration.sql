-- Status parity: privacy modes + music + highlights
-- Project: ljnparociyyggmxdewwv

-- 1) Status privacy mode
alter table public.profiles
  add column if not exists status_privacy_mode text not null default 'all';

-- 2) Only-share-with list (allow-list)
create table if not exists public.status_privacy_allowed (
  user_id uuid not null references public.profiles(id) on delete cascade,
  allowed_user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, allowed_user_id)
);

alter table public.status_privacy_allowed enable row level security;

drop policy if exists "Users can manage own status privacy allowed" on public.status_privacy_allowed;
create policy "Users can manage own status privacy allowed" on public.status_privacy_allowed
for all to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

-- 3) Optional status music fields
alter table public.status
  add column if not exists music_path text,
  add column if not exists music_mime text,
  add column if not exists music_start_ms integer;

-- 4) Highlights: keep selected status in a separate list (even after 19h expiry, it stays as a highlight reference)
create table if not exists public.status_highlights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  status_id uuid not null references public.status(id) on delete cascade,
  title text,
  created_at timestamptz not null default now(),
  unique(user_id, status_id)
);

alter table public.status_highlights enable row level security;

drop policy if exists "Users can manage own highlights" on public.status_highlights;
create policy "Users can manage own highlights" on public.status_highlights
for all to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

-- Realtime
alter publication supabase_realtime add table public.status_privacy_allowed;
alter publication supabase_realtime add table public.status_highlights;
