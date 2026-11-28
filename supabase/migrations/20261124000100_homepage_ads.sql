-- Homepage advertising banners managed by administrators.
create table if not exists public.homepage_ads (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  subtitle text not null default '',
  image_path text not null,
  tournament_id uuid references public.tournaments(id) on delete set null,
  target_url text not null default 'tournaments.html',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Also supports projects where the original homepage_ads table was created earlier.
alter table public.homepage_ads
  add column if not exists tournament_id uuid references public.tournaments(id) on delete set null;

alter table public.homepage_ads enable row level security;
grant select on public.homepage_ads to anon, authenticated;
grant insert, update, delete on public.homepage_ads to authenticated;

drop policy if exists "Public can read active homepage ads" on public.homepage_ads;
create policy "Public can read active homepage ads"
on public.homepage_ads for select to anon, authenticated
using (is_active = true);

drop policy if exists "Admins can manage homepage ads" on public.homepage_ads;
create policy "Admins can manage homepage ads"
on public.homepage_ads for all to authenticated
using (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
)
with check (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create index if not exists homepage_ads_active_order_idx
on public.homepage_ads (is_active, sort_order, created_at desc);

create index if not exists homepage_ads_tournament_idx
on public.homepage_ads (tournament_id);

notify pgrst, 'reload schema';
