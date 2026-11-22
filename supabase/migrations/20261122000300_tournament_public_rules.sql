-- Store public-facing rules separately for each tournament.
create table if not exists public.tournament_public_rules (
  tournament_id uuid primary key references public.tournaments(id) on delete cascade,
  rules_text text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

alter table public.tournament_public_rules enable row level security;

drop policy if exists "Public can read tournament rules" on public.tournament_public_rules;
create policy "Public can read tournament rules"
on public.tournament_public_rules
for select
to anon, authenticated
using (true);

create or replace function public.save_tournament_public_rules(
  p_tournament_id uuid,
  p_rules_text text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'برای ذخیره قوانین باید وارد حساب مدیریتی شوید.';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role in ('admin', 'manager')
  ) then
    raise exception 'شما مجوز مدیریت قوانین تورنمنت را ندارید.';
  end if;

  if not exists (
    select 1
    from public.get_manageable_tournaments() mt
    where mt.tournament_id = p_tournament_id
  ) then
    raise exception 'این تورنمنت در دسترس مدیریتی حساب شما نیست.';
  end if;

  insert into public.tournament_public_rules (
    tournament_id, rules_text, updated_at, updated_by
  )
  values (
    p_tournament_id, coalesce(p_rules_text, ''), now(), auth.uid()
  )
  on conflict (tournament_id) do update
  set rules_text = excluded.rules_text,
      updated_at = now(),
      updated_by = auth.uid();
end;
$$;

revoke all on function public.save_tournament_public_rules(uuid, text) from public, anon;
grant execute on function public.save_tournament_public_rules(uuid, text) to authenticated;

notify pgrst, 'reload schema';
