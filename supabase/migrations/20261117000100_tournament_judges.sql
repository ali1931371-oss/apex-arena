-- APEX ARENA: tournament-scoped judge appointments.
-- Apply this migration in Supabase SQL Editor only after reviewing it.
-- Judges remain ordinary player accounts globally; their judge status is scoped to one tournament.
-- No service-role key is used by the application.

begin;

create table if not exists public.tournament_judges (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  judge_id uuid not null references public.profiles(id) on delete restrict,
  appointed_by uuid not null references public.profiles(id) on delete restrict,
  appointed_at timestamptz not null default now(),
  status text not null default 'active'
    check (status in ('active', 'revoked')),
  revoked_by uuid references public.profiles(id) on delete set null,
  revoked_at timestamptz,
  restore_as_player boolean not null default false,
  constraint tournament_judges_revocation_state_check check (
    (status = 'active' and revoked_by is null and revoked_at is null and restore_as_player = false)
    or
    (status = 'revoked' and revoked_at is not null)
  )
);

create unique index if not exists tournament_judges_one_active_per_tournament
  on public.tournament_judges (tournament_id, judge_id)
  where status = 'active';

create index if not exists tournament_judges_tournament_status_idx
  on public.tournament_judges (tournament_id, status);

create index if not exists tournament_judges_judge_idx
  on public.tournament_judges (judge_id);

alter table public.tournament_judges enable row level security;

create or replace function public.is_apex_manager()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role in ('admin', 'manager')
  );
$function$;

revoke all on function public.is_apex_manager() from public;
grant execute on function public.is_apex_manager() to authenticated;

drop policy if exists tournament_judges_manager_read on public.tournament_judges;
create policy tournament_judges_manager_read
on public.tournament_judges
for select to authenticated
using ((select public.is_apex_manager()));

drop policy if exists tournament_judges_judge_read_own on public.tournament_judges;
create policy tournament_judges_judge_read_own
on public.tournament_judges
for select to authenticated
using (judge_id = (select auth.uid()));

drop policy if exists judge_assignments_manager_read on public.judge_assignments;
create policy judge_assignments_manager_read
on public.judge_assignments
for select to authenticated
using ((select public.is_apex_manager()));

drop policy if exists judge_assignments_judge_read_own on public.judge_assignments;
create policy judge_assignments_judge_read_own
on public.judge_assignments
for select to authenticated
using (
  judge_id = (select auth.uid())
  and exists (
    select 1
    from public.matches m
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id
     and tj.judge_id = judge_assignments.judge_id
     and tj.status = 'active'
    where m.id = judge_assignments.match_id
  )
);

-- Return only safe fields needed by the manager's judge picker.
create or replace function public.list_eligible_tournament_judges(p_tournament_id uuid)
returns table (
  judge_id uuid,
  display_name text,
  player_code text,
  audio_player_id text,
  username text
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not public.is_apex_manager() then
    raise exception 'اجازه مشاهده فهرست داوران را ندارید.';
  end if;

  if not exists (
    select 1 from public.tournaments t where t.id = p_tournament_id
  ) then
    raise exception 'تورنمنت پیدا نشد.';
  end if;

  return query
  select distinct
    p.id,
    p.display_name,
    pl.player_code,
    pl.audio_player_id,
    p.username
  from public.tournament_registration_requests r
  join public.profiles p on p.id = r.user_id and p.role = 'player'
  join public.players pl on pl.user_id = p.id
  where r.tournament_id = p_tournament_id
    and r.status = 'approved'
    and not exists (
      select 1
      from public.tournament_judges tj
      where tj.tournament_id = p_tournament_id
        and tj.judge_id = p.id
        and (
          tj.status = 'active'
          or (tj.status = 'revoked' and tj.restore_as_player = false)
        )
    )
    and not exists (
      select 1
      from public.match_players mp
      join public.matches m on m.id = mp.match_id
      where m.tournament_id = p_tournament_id
        and mp.player_id = pl.id
    )
  order by p.display_name;
end;
$function$;

revoke all on function public.list_eligible_tournament_judges(uuid) from public;
grant execute on function public.list_eligible_tournament_judges(uuid) to authenticated;


-- Current and historical tournament judge appointments for the manager panel.
create or replace function public.list_tournament_judges(p_tournament_id uuid)
returns table (
  judge_id uuid,
  display_name text,
  player_code text,
  appointed_at timestamptz,
  status text,
  restore_as_player boolean,
  assigned_match_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not public.is_apex_manager() then
    raise exception 'اجازه مشاهده فهرست داوران را ندارید.';
  end if;

  return query
  select
    tj.judge_id,
    p.display_name,
    pl.player_code,
    tj.appointed_at,
    tj.status,
    tj.restore_as_player,
    (
      select count(*)
      from public.judge_assignments ja
      join public.matches m on m.id = ja.match_id
      where ja.judge_id = tj.judge_id
        and m.tournament_id = tj.tournament_id
    )
  from public.tournament_judges tj
  join public.profiles p on p.id = tj.judge_id
  left join public.players pl on pl.user_id = tj.judge_id
  where tj.tournament_id = p_tournament_id
  order by case when tj.status = 'active' then 0 else 1 end, tj.appointed_at desc;
end;
$function$;

revoke all on function public.list_tournament_judges(uuid) from public;
grant execute on function public.list_tournament_judges(uuid) to authenticated;

create or replace function public.assign_tournament_judge(
  p_tournament_id uuid,
  p_judge_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_name text;
  v_existing_id uuid;
begin
  if auth.uid() is null or not public.is_apex_manager() then
    raise exception 'فقط مدیر مجاز به انتصاب داور است.';
  end if;

  perform 1
  from public.tournaments t
  where t.id = p_tournament_id
  for update;

  if not found then
    raise exception 'تورنمنت پیدا نشد.';
  end if;

  select p.display_name
    into v_name
  from public.profiles p
  join public.players pl on pl.user_id = p.id
  where p.id = p_judge_id
    and p.role = 'player'
    and exists (
      select 1
      from public.tournament_registration_requests r
      where r.tournament_id = p_tournament_id
        and r.user_id = p_judge_id
        and r.status = 'approved'
    );

  if v_name is null then
    raise exception 'فقط بازیکن ثبت‌نام‌شده و تأییدشده این تورنمنت می‌تواند داور شود.';
  end if;

  if exists (
    select 1
    from public.match_players mp
    join public.players pl on pl.id = mp.player_id
    join public.matches m on m.id = mp.match_id
    where m.tournament_id = p_tournament_id
      and pl.user_id = p_judge_id
  ) then
    raise exception 'این بازیکن در یکی از بازی‌های تورنمنت شرکت کرده است و قابل انتصاب به داوری نیست.';
  end if;

  select tj.id
    into v_existing_id
  from public.tournament_judges tj
  where tj.tournament_id = p_tournament_id
    and tj.judge_id = p_judge_id
    and tj.status = 'active'
  limit 1;

  if v_existing_id is null then
    insert into public.tournament_judges (
      tournament_id, judge_id, appointed_by
    )
    values (
      p_tournament_id, p_judge_id, auth.uid()
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'judge_id', p_judge_id,
    'display_name', v_name
  );
end;
$function$;

revoke all on function public.assign_tournament_judge(uuid, uuid) from public;
grant execute on function public.assign_tournament_judge(uuid, uuid) to authenticated;

create or replace function public.revoke_tournament_judge(
  p_tournament_id uuid,
  p_judge_id uuid,
  p_restore_as_player boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_count integer;
begin
  if auth.uid() is null or not public.is_apex_manager() then
    raise exception 'فقط مدیر مجاز به لغو انتصاب داور است.';
  end if;

  update public.tournament_judges
  set
    status = 'revoked',
    revoked_by = auth.uid(),
    revoked_at = now(),
    restore_as_player = coalesce(p_restore_as_player, false)
  where tournament_id = p_tournament_id
    and judge_id = p_judge_id
    and status = 'active';

  get diagnostics v_count = row_count;

  if v_count = 0 then
    raise exception 'انتصاب فعال داور پیدا نشد.';
  end if;

  -- Remove match-level permissions. Historical scores remain intact.
  delete from public.judge_assignments ja
  using public.matches m
  where ja.match_id = m.id
    and m.tournament_id = p_tournament_id
    and ja.judge_id = p_judge_id;

  return jsonb_build_object(
    'success', true,
    'restore_as_player', coalesce(p_restore_as_player, false)
  );
end;
$function$;

revoke all on function public.revoke_tournament_judge(uuid, uuid, boolean) from public;
grant execute on function public.revoke_tournament_judge(uuid, uuid, boolean) to authenticated;

create or replace function public.assign_judge_to_match(
  p_match_id uuid,
  p_judge_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_tournament_id uuid;
begin
  if auth.uid() is null or not public.is_apex_manager() then
    raise exception 'فقط مدیر مجاز به تخصیص داور به بازی است.';
  end if;

  select m.tournament_id
    into v_tournament_id
  from public.matches m
  where m.id = p_match_id
    and m.status <> 'cancelled'
  for update;

  if v_tournament_id is null then
    raise exception 'بازی پیدا نشد یا لغو شده است.';
  end if;

  if not exists (
    select 1
    from public.tournament_judges tj
    where tj.tournament_id = v_tournament_id
      and tj.judge_id = p_judge_id
      and tj.status = 'active'
  ) then
    raise exception 'این حساب داور فعال این تورنمنت نیست.';
  end if;

  if exists (
    select 1
    from public.match_players mp
    join public.players pl on pl.id = mp.player_id
    where mp.match_id = p_match_id
      and pl.user_id = p_judge_id
  ) then
    raise exception 'داور این بازی نمی‌تواند هم‌زمان شرکت‌کننده آن باشد.';
  end if;

  insert into public.judge_assignments (match_id, judge_id)
  values (p_match_id, p_judge_id)
  on conflict (match_id, judge_id) do nothing;

  return jsonb_build_object('success', true);
end;
$function$;

revoke all on function public.assign_judge_to_match(uuid, uuid) from public;
grant execute on function public.assign_judge_to_match(uuid, uuid) to authenticated;

create or replace function public.unassign_judge_from_match(
  p_match_id uuid,
  p_judge_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not public.is_apex_manager() then
    raise exception 'فقط مدیر مجاز به لغو تخصیص داور است.';
  end if;

  delete from public.judge_assignments
  where match_id = p_match_id
    and judge_id = p_judge_id;

  return jsonb_build_object('success', true);
end;
$function$;

revoke all on function public.unassign_judge_from_match(uuid, uuid) from public;
grant execute on function public.unassign_judge_from_match(uuid, uuid) to authenticated;

-- Keep approved-player capacity separate from active judges and people not restored as players.
create or replace function public.get_open_tournaments()
returns table (
  tournament_id uuid,
  tournament_name text,
  tournament_slug text,
  tournament_description text,
  max_players integer,
  approved_players bigint,
  available_slots integer
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    t.id,
    t.name,
    t.slug,
    t.description,
    s.max_players,
    (
      select count(distinct p.id)
      from public.tournament_registration_requests r
      join public.profiles p on p.id = r.user_id and p.role = 'player'
      join public.players pl on pl.user_id = p.id
      where r.tournament_id = t.id
        and r.status = 'approved'
        and not exists (
          select 1
          from public.tournament_judges tj
          where tj.tournament_id = t.id
            and tj.judge_id = p.id
            and (
              tj.status = 'active'
              or (tj.status = 'revoked' and tj.restore_as_player = false)
            )
        )
    ),
    greatest(
      s.max_players - (
        select count(distinct p.id)::integer
        from public.tournament_registration_requests r
        join public.profiles p on p.id = r.user_id and p.role = 'player'
        join public.players pl on pl.user_id = p.id
        where r.tournament_id = t.id
          and r.status = 'approved'
          and not exists (
            select 1
            from public.tournament_judges tj
            where tj.tournament_id = t.id
              and tj.judge_id = p.id
              and (
                tj.status = 'active'
                or (tj.status = 'revoked' and tj.restore_as_player = false)
              )
          )
      ),
      0
    )
  from public.tournaments t
  join public.tournament_registration_settings s on s.tournament_id = t.id
  where t.status = 'registration'
    and s.registration_open = true
  order by t.created_at desc;
$function$;

revoke all on function public.get_open_tournaments() from public;
grant execute on function public.get_open_tournaments() to anon, authenticated;

-- Approval now locks capacity settings and counts only actual players.
create or replace function public.approve_player_registration(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_request record;
  v_actor_role text;
  v_settings record;
  v_display_name text;
  v_player_code text;
  v_approved_count integer;
begin
  if auth.uid() is null then
    raise exception 'ابتدا باید وارد حساب کاربری شوید.';
  end if;

  select p.role into v_actor_role
  from public.profiles p
  where p.id = auth.uid();

  if v_actor_role is null or v_actor_role not in ('admin', 'manager') then
    raise exception 'شما اجازه تأیید ثبت‌نام را ندارید.';
  end if;

  select *
    into v_request
  from public.tournament_registration_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'درخواست ثبت‌نام پیدا نشد.';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'این درخواست قبلاً بررسی شده است.';
  end if;

  select s.*
    into v_settings
  from public.tournament_registration_settings s
  where s.tournament_id = v_request.tournament_id
  for update;

  if not found or not v_settings.registration_open then
    raise exception 'ثبت‌نام این تورنمنت بسته است یا تنظیمات آن وجود ندارد.';
  end if;

  if not exists (
    select 1 from public.tournaments t
    where t.id = v_request.tournament_id and t.status = 'registration'
  ) then
    raise exception 'وضعیت تورنمنت اجازه تأیید نمی‌دهد.';
  end if;

  select count(*)::integer
    into v_approved_count
  from public.tournament_registration_requests r
  join public.profiles p on p.id = r.user_id and p.role = 'player'
  join public.players pl on pl.user_id = p.id
  where r.tournament_id = v_request.tournament_id
    and r.status = 'approved'
    and not exists (
      select 1
      from public.tournament_judges tj
      where tj.tournament_id = v_request.tournament_id
        and tj.judge_id = p.id
        and (
          tj.status = 'active'
          or (tj.status = 'revoked' and tj.restore_as_player = false)
        )
    );

  if v_approved_count >= v_settings.max_players then
    raise exception 'ظرفیت بازیکنان تورنمنت تکمیل شده است.';
  end if;

  v_display_name := coalesce(
    nullif(trim(v_request.full_name), ''),
    nullif(trim(v_request.requested_display_name), '')
  );

  if v_display_name is null then
    raise exception 'نام بازیکن ثبت نشده است.';
  end if;

  insert into public.profiles (id, display_name, role, username, phone)
  values (v_request.user_id, v_display_name, 'player', v_request.username, v_request.phone)
  on conflict (id) do update
  set
    display_name = excluded.display_name,
    username = coalesce(excluded.username, public.profiles.username),
    phone = coalesce(excluded.phone, public.profiles.phone)
  where public.profiles.role = 'player';

  if not found then
    raise exception 'نقش حساب موجود اجازه ثبت‌نام به‌عنوان بازیکن را نمی‌دهد.';
  end if;

  select pl.player_code
    into v_player_code
  from public.players pl
  where pl.user_id = v_request.user_id;

  if v_player_code is null then
    v_player_code := 'APX-' || nextval('public.player_code_seq')::text;
    insert into public.players (user_id, player_code, display_name, audio_player_id)
    values (v_request.user_id, v_player_code, v_display_name, v_request.audio_player_id);
  else
    update public.players
    set display_name = v_display_name,
        audio_player_id = coalesce(v_request.audio_player_id, audio_player_id)
    where user_id = v_request.user_id;
  end if;

  update public.tournament_registration_requests
  set status = 'approved',
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where id = p_request_id;

  return jsonb_build_object(
    'success', true,
    'message', 'ثبت‌نام بازیکن با موفقیت تأیید شد.',
    'player_code', v_player_code,
    'user_id', v_request.user_id
  );
end;
$function$;

revoke all on function public.approve_player_registration(uuid) from public;
grant execute on function public.approve_player_registration(uuid) to authenticated;

-- Keep the legacy review RPC aligned with the same capacity and role checks.
create or replace function public.review_registration(
  p_request_id uuid,
  p_decision text,
  p_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_request public.tournament_registration_requests%rowtype;
  v_result jsonb;
begin
  if auth.uid() is null or not public.is_apex_manager() then
    raise exception 'اجازه انجام این عملیات را ندارید.';
  end if;

  if p_decision not in ('approved', 'rejected') then
    raise exception 'وضعیت باید approved یا rejected باشد.';
  end if;

  select * into v_request
  from public.tournament_registration_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    return false;
  end if;

  if p_decision = 'approved' then
    v_result := public.approve_player_registration(p_request_id);
    update public.tournament_registration_requests
    set review_note = p_note
    where id = p_request_id;
  else
    update public.tournament_registration_requests
    set status = 'rejected',
        reviewed_by = auth.uid(),
        review_note = p_note,
        reviewed_at = now()
    where id = p_request_id;
  end if;

  return true;
end;
$function$;

revoke all on function public.review_registration(uuid, text, text) from public;
grant execute on function public.review_registration(uuid, text, text) to authenticated;

-- Audit appointment and match-assignment lifecycle with the existing audit trigger.
drop trigger if exists audit_tournament_judges on public.tournament_judges;
create trigger audit_tournament_judges
after insert or update or delete on public.tournament_judges
for each row execute function public.log_score_changes();

drop trigger if exists audit_judge_assignments on public.judge_assignments;
create trigger audit_judge_assignments
after insert or update or delete on public.judge_assignments
for each row execute function public.log_score_changes();

commit;
