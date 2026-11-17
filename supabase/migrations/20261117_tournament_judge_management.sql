-- APEX ARENA: tournament-scoped judge management
-- Apply only to the Supabase project after reviewing this migration.
-- Judges remain player accounts globally; their judge appointment is scoped to a tournament.

begin;

create or replace function public.is_apex_manager()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role in ('admin', 'manager')
  );
$$;

revoke all on function public.is_apex_manager() from public;
grant execute on function public.is_apex_manager() to authenticated;

create table if not exists public.tournament_judges (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  assigned_by uuid not null references public.profiles(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  revoked_by uuid references public.profiles(id) on delete set null,
  revoked_at timestamptz,
  note text,
  constraint tournament_judges_tournament_user_key unique (tournament_id, user_id)
);

alter table public.judge_assignments
  add column if not exists assigned_by uuid references public.profiles(id) on delete set null,
  add column if not exists revoked_by uuid references public.profiles(id) on delete set null,
  add column if not exists revoked_at timestamptz;

alter table public.tournament_judges enable row level security;

drop policy if exists tournament_judges_manager_access on public.tournament_judges;
create policy tournament_judges_manager_access
on public.tournament_judges
for all to authenticated
using ((select public.is_apex_manager()))
with check ((select public.is_apex_manager()));

drop policy if exists tournament_judges_read_own on public.tournament_judges;
create policy tournament_judges_read_own
on public.tournament_judges
for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists apex_admin_full_access on public.judge_assignments;
drop policy if exists judge_assignments_manager_access on public.judge_assignments;
create policy judge_assignments_manager_access
on public.judge_assignments
for all to authenticated
using ((select public.is_apex_manager()))
with check ((select public.is_apex_manager()));

drop policy if exists judge_assignments_read_own_active on public.judge_assignments;
create policy judge_assignments_read_own_active
on public.judge_assignments
for select to authenticated
using (
  judge_id = (select auth.uid())
  and revoked_at is null
  and exists (
    select 1
    from public.matches m
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id
    where m.id = judge_assignments.match_id
      and tj.user_id = judge_assignments.judge_id
      and tj.revoked_at is null
  )
);

-- Judges can see only their own active work and their own submissions.
drop policy if exists judge_read_own_submissions on public.score_submissions;
create policy judge_read_own_submissions
on public.score_submissions
for select to authenticated
using (
  judge_id = (select auth.uid())
  and exists (
    select 1
    from public.judge_assignments ja
    join public.matches m on m.id = ja.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id
     and tj.user_id = ja.judge_id
    where ja.match_id = score_submissions.match_id
      and ja.judge_id = (select auth.uid())
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status <> 'cancelled'
  )
);

drop policy if exists judge_insert_own_submissions on public.score_submissions;
create policy judge_insert_own_submissions
on public.score_submissions
for insert to authenticated
with check (
  judge_id = (select auth.uid())
  and status in ('draft', 'submitted')
  and exists (
    select 1
    from public.judge_assignments ja
    join public.matches m on m.id = ja.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id
     and tj.user_id = ja.judge_id
    join public.match_players mp
      on mp.match_id = m.id
     and mp.player_id = score_submissions.player_id
    where ja.match_id = score_submissions.match_id
      and ja.judge_id = (select auth.uid())
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status in ('scheduled', 'live')
  )
);

drop policy if exists judge_update_own_submissions on public.score_submissions;
create policy judge_update_own_submissions
on public.score_submissions
for update to authenticated
using (
  judge_id = (select auth.uid())
  and status in ('draft', 'submitted')
  and exists (
    select 1
    from public.judge_assignments ja
    join public.matches m on m.id = ja.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id
     and tj.user_id = ja.judge_id
    where ja.match_id = score_submissions.match_id
      and ja.judge_id = (select auth.uid())
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status in ('scheduled', 'live')
  )
)
with check (
  judge_id = (select auth.uid())
  and status in ('draft', 'submitted')
  and exists (
    select 1
    from public.judge_assignments ja
    join public.matches m on m.id = ja.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id
     and tj.user_id = ja.judge_id
    join public.match_players mp
      on mp.match_id = m.id
     and mp.player_id = score_submissions.player_id
    where ja.match_id = score_submissions.match_id
      and ja.judge_id = (select auth.uid())
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status in ('scheduled', 'live')
  )
);

-- A judge may read/enter criterion rows only under their own authorized submission.
drop policy if exists judge_read_own_score_items on public.score_items;
create policy judge_read_own_score_items
on public.score_items
for select to authenticated
using (
  exists (
    select 1
    from public.score_submissions ss
    join public.judge_assignments ja
      on ja.match_id = ss.match_id and ja.judge_id = ss.judge_id
    join public.matches m on m.id = ss.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id and tj.user_id = ss.judge_id
    where ss.id = score_items.submission_id
      and ss.judge_id = (select auth.uid())
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status <> 'cancelled'
  )
);

drop policy if exists judge_insert_own_score_items on public.score_items;
create policy judge_insert_own_score_items
on public.score_items
for insert to authenticated
with check (
  raw_points >= 0
  and exists (
    select 1
    from public.score_submissions ss
    join public.judge_assignments ja
      on ja.match_id = ss.match_id and ja.judge_id = ss.judge_id
    join public.matches m on m.id = ss.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id and tj.user_id = ss.judge_id
    join public.tournament_criteria tc
      on tc.id = score_items.criterion_id
     and tc.tournament_id = m.tournament_id
     and tc.is_active = true
    where ss.id = score_items.submission_id
      and ss.judge_id = (select auth.uid())
      and ss.status in ('draft', 'submitted')
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status in ('scheduled', 'live')
      and score_items.raw_points between tc.min_points and tc.max_points
  )
);

drop policy if exists judge_update_own_score_items on public.score_items;
create policy judge_update_own_score_items
on public.score_items
for update to authenticated
using (
  exists (
    select 1
    from public.score_submissions ss
    join public.judge_assignments ja
      on ja.match_id = ss.match_id and ja.judge_id = ss.judge_id
    join public.matches m on m.id = ss.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id and tj.user_id = ss.judge_id
    where ss.id = score_items.submission_id
      and ss.judge_id = (select auth.uid())
      and ss.status in ('draft', 'submitted')
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status in ('scheduled', 'live')
  )
)
with check (
  raw_points >= 0
  and exists (
    select 1
    from public.score_submissions ss
    join public.judge_assignments ja
      on ja.match_id = ss.match_id and ja.judge_id = ss.judge_id
    join public.matches m on m.id = ss.match_id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id and tj.user_id = ss.judge_id
    join public.tournament_criteria tc
      on tc.id = score_items.criterion_id
     and tc.tournament_id = m.tournament_id
     and tc.is_active = true
    where ss.id = score_items.submission_id
      and ss.judge_id = (select auth.uid())
      and ss.status in ('draft', 'submitted')
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status in ('scheduled', 'live')
      and score_items.raw_points between tc.min_points and tc.max_points
  )
);

drop policy if exists judge_read_assigned_players on public.players;
create policy judge_read_assigned_players
on public.players
for select to authenticated
using (
  exists (
    select 1
    from public.match_players mp
    join public.matches m on m.id = mp.match_id
    join public.judge_assignments ja on ja.match_id = m.id
    join public.tournament_judges tj
      on tj.tournament_id = m.tournament_id
     and tj.user_id = ja.judge_id
    where mp.player_id = players.id
      and ja.judge_id = (select auth.uid())
      and ja.revoked_at is null
      and tj.revoked_at is null
      and m.status <> 'cancelled'
  )
);

-- Manager visibility for reviewing scores and audit history.
drop policy if exists manager_read_score_submissions on public.score_submissions;
create policy manager_read_score_submissions
on public.score_submissions
for select to authenticated
using ((select public.is_apex_manager()));

drop policy if exists manager_read_score_items on public.score_items;
create policy manager_read_score_items
on public.score_items
for select to authenticated
using ((select public.is_apex_manager()));

drop policy if exists manager_read_score_adjustments on public.score_adjustments;
create policy manager_read_score_adjustments
on public.score_adjustments
for select to authenticated
using ((select public.is_apex_manager()));

drop policy if exists manager_read_audit_logs on public.audit_logs;
create policy manager_read_audit_logs
on public.audit_logs
for select to authenticated
using ((select public.is_apex_manager()));

-- Eligibility list contains only approved players in the selected tournament.
create or replace function public.get_eligible_tournament_judges(p_tournament_id uuid)
returns table (
  user_id uuid,
  display_name text,
  player_code text,
  audio_player_id text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_apex_manager() then
    raise exception 'اجازه مشاهده فهرست داوران را ندارید.';
  end if;

  return query
  select distinct p.id, p.display_name, pl.player_code, pl.audio_player_id
  from public.tournament_registration_requests r
  join public.profiles p on p.id = r.user_id and p.role = 'player'
  join public.players pl on pl.user_id = p.id
  where r.tournament_id = p_tournament_id
    and r.status = 'approved'
    and not exists (
      select 1
      from public.tournament_judges tj
      where tj.tournament_id = p_tournament_id
        and tj.user_id = p.id
        and tj.revoked_at is null
    )
    and not exists (
      select 1
      from public.match_players mp
      join public.matches m on m.id = mp.match_id
      where m.tournament_id = p_tournament_id
        and m.status <> 'cancelled'
        and mp.player_id = pl.id
    )
  order by p.display_name;
end;
$$;

create or replace function public.appoint_tournament_judge(
  p_tournament_id uuid,
  p_user_id uuid,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player_id uuid;
  v_id uuid;
begin
  if not public.is_apex_manager() then
    raise exception 'فقط مدیر یا مدیر اجرایی می‌تواند داور منصوب کند.';
  end if;

  if not exists (
    select 1
    from public.tournament_registration_requests r
    where r.tournament_id = p_tournament_id
      and r.user_id = p_user_id
      and r.status = 'approved'
  ) then
    raise exception 'فقط بازیکن تأییدشده همین تورنمنت قابل انتصاب است.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = p_user_id and p.role = 'player'
  ) then
    raise exception 'این حساب در حال حاضر نقش بازیکن ندارد.';
  end if;

  select pl.id into v_player_id
  from public.players pl
  where pl.user_id = p_user_id;

  if v_player_id is null then
    raise exception 'رکورد بازیکن پیدا نشد.';
  end if;

  if exists (
    select 1
    from public.match_players mp
    join public.matches m on m.id = mp.match_id
    where m.tournament_id = p_tournament_id
      and m.status <> 'cancelled'
      and mp.player_id = v_player_id
  ) then
    raise exception 'این بازیکن در ترکیب مسابقه ثبت شده است؛ ابتدا وضعیت حضور او را در مسابقه‌ها تعیین تکلیف کنید.';
  end if;

  insert into public.tournament_judges (
    tournament_id, user_id, assigned_by, assigned_at, revoked_by, revoked_at, note
  )
  values (
    p_tournament_id, p_user_id, auth.uid(), now(), null, null, p_note
  )
  on conflict (tournament_id, user_id) do update
  set assigned_by = excluded.assigned_by,
      assigned_at = now(),
      revoked_by = null,
      revoked_at = null,
      note = excluded.note
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.assign_judge_to_match(
  p_match_id uuid,
  p_judge_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tournament_id uuid;
  v_id uuid;
begin
  if not public.is_apex_manager() then
    raise exception 'اجازه تخصیص داور را ندارید.';
  end if;

  select m.tournament_id into v_tournament_id
  from public.matches m
  where m.id = p_match_id
    and m.status in ('scheduled', 'live');

  if v_tournament_id is null then
    raise exception 'مسابقه پیدا نشد یا در وضعیت قابل داوری نیست.';
  end if;

  if not exists (
    select 1 from public.tournament_judges tj
    where tj.tournament_id = v_tournament_id
      and tj.user_id = p_judge_id
      and tj.revoked_at is null
  ) then
    raise exception 'این فرد داور فعال همین تورنمنت نیست.';
  end if;

  insert into public.judge_assignments (
    match_id, judge_id, assigned_at, assigned_by, revoked_by, revoked_at
  )
  values (p_match_id, p_judge_id, now(), auth.uid(), null, null)
  on conflict (match_id, judge_id) do update
  set assigned_at = now(),
      assigned_by = auth.uid(),
      revoked_by = null,
      revoked_at = null
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.revoke_judge_from_match(
  p_match_id uuid,
  p_judge_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_apex_manager() then
    raise exception 'اجازه لغو تخصیص داور را ندارید.';
  end if;

  update public.judge_assignments
  set revoked_at = now(), revoked_by = auth.uid()
  where match_id = p_match_id
    and judge_id = p_judge_id
    and revoked_at is null;

  return found;
end;
$$;

create or replace function public.revoke_tournament_judge(
  p_tournament_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_apex_manager() then
    raise exception 'اجازه لغو انتصاب داور را ندارید.';
  end if;

  update public.tournament_judges
  set revoked_at = now(), revoked_by = auth.uid()
  where tournament_id = p_tournament_id
    and user_id = p_user_id
    and revoked_at is null;

  if not found then
    return false;
  end if;

  update public.judge_assignments ja
  set revoked_at = now(), revoked_by = auth.uid()
  from public.matches m
  where ja.match_id = m.id
    and m.tournament_id = p_tournament_id
    and ja.judge_id = p_user_id
    and ja.revoked_at is null;

  return true;
end;
$$;

create or replace function public.get_judge_worklist()
returns table (
  match_id uuid,
  tournament_id uuid,
  tournament_name text,
  match_number integer,
  match_status text,
  assigned_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select m.id, m.tournament_id, t.name, m.match_number, m.status, ja.assigned_at
  from public.judge_assignments ja
  join public.matches m on m.id = ja.match_id
  join public.tournaments t on t.id = m.tournament_id
  join public.tournament_judges tj
    on tj.tournament_id = m.tournament_id
   and tj.user_id = ja.judge_id
  where ja.judge_id = (select auth.uid())
    and ja.revoked_at is null
    and tj.revoked_at is null
    and m.status in ('scheduled', 'live')
  order by ja.assigned_at desc;
$$;

-- Keep approved player capacity separate from appointed judges.
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
as $$
  select
    t.id,
    t.name,
    t.slug,
    t.description,
    s.max_players,
    (
      select count(distinct r.user_id)
      from public.tournament_registration_requests r
      join public.profiles p on p.id = r.user_id and p.role = 'player'
      join public.players pl on pl.user_id = p.id
      where r.tournament_id = t.id
        and r.status = 'approved'
        and not exists (
          select 1 from public.tournament_judges tj
          where tj.tournament_id = t.id
            and tj.user_id = r.user_id
            and tj.revoked_at is null
        )
    ),
    greatest(
      s.max_players - (
        select count(distinct r.user_id)::integer
        from public.tournament_registration_requests r
        join public.profiles p on p.id = r.user_id and p.role = 'player'
        join public.players pl on pl.user_id = p.id
        where r.tournament_id = t.id
          and r.status = 'approved'
          and not exists (
            select 1 from public.tournament_judges tj
            where tj.tournament_id = t.id
              and tj.user_id = r.user_id
              and tj.revoked_at is null
          )
      ),
      0
    )
  from public.tournaments t
  join public.tournament_registration_settings s on s.tournament_id = t.id
  where t.status = 'registration'
    and s.registration_open = true
  order by t.created_at desc;
$$;

-- One canonical approval path: manager/admin, capacity check, and role-safe profile upsert.
create or replace function public.review_registration(
  p_request_id uuid,
  p_decision text,
  p_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request record;
  v_settings record;
  v_approved_count integer;
  v_player_code text;
  v_display_name text;
begin
  if not public.is_apex_manager() then
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
    select s.* into v_settings
    from public.tournament_registration_settings s
    where s.tournament_id = v_request.tournament_id
    for update;

    if not found or not v_settings.registration_open then
      raise exception 'ثبت‌نام این تورنمنت باز نیست.';
    end if;

    if not exists (
      select 1 from public.tournaments t
      where t.id = v_request.tournament_id and t.status = 'registration'
    ) then
      raise exception 'وضعیت تورنمنت اجازه تأیید نمی‌دهد.';
    end if;

    select count(distinct r.user_id)::integer into v_approved_count
    from public.tournament_registration_requests r
    join public.profiles p on p.id = r.user_id and p.role = 'player'
    join public.players pl on pl.user_id = p.id
    where r.tournament_id = v_request.tournament_id
      and r.status = 'approved'
      and not exists (
        select 1 from public.tournament_judges tj
        where tj.tournament_id = v_request.tournament_id
          and tj.user_id = r.user_id
          and tj.revoked_at is null
      );

    if v_approved_count >= v_settings.max_players then
      raise exception 'ظرفیت تورنمنت تکمیل شده است.';
    end if;

    v_display_name := coalesce(
      nullif(btrim(v_request.full_name), ''),
      nullif(btrim(v_request.requested_display_name), '')
    );

    if v_display_name is null then
      raise exception 'نام بازیکن ثبت نشده است.';
    end if;

    insert into public.profiles (id, display_name, role, username, phone)
    values (v_request.user_id, v_display_name, 'player', v_request.username, v_request.phone)
    on conflict (id) do update
    set display_name = excluded.display_name,
        username = coalesce(excluded.username, public.profiles.username),
        phone = coalesce(excluded.phone, public.profiles.phone)
    where public.profiles.role = 'player';

    if not found then
      raise exception 'نقش حساب موجود اجازه ثبت‌نام به‌عنوان بازیکن را نمی‌دهد.';
    end if;

    if not exists (
      select 1 from public.players pl where pl.user_id = v_request.user_id
    ) then
      loop
        v_player_code := 'APX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
        begin
          insert into public.players (
            user_id, player_code, display_name, avatar_url, public_profile, audio_player_id
          )
          values (
            v_request.user_id, v_player_code, v_display_name, null, false, v_request.audio_player_id
          );
          exit;
        exception when unique_violation then
          if exists (select 1 from public.players pl where pl.user_id = v_request.user_id) then
            exit;
          end if;
        end;
      end loop;
    end if;
  end if;

  update public.tournament_registration_requests
  set status = p_decision,
      reviewed_by = auth.uid(),
      review_note = p_note,
      reviewed_at = now()
  where id = p_request_id;

  return true;
end;
$$;

create or replace function public.approve_player_registration(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_ok boolean;
  v_player_code text;
begin
  select user_id into v_user_id
  from public.tournament_registration_requests
  where id = p_request_id;

  if v_user_id is null then
    raise exception 'درخواست ثبت‌نام پیدا نشد.';
  end if;

  v_ok := public.review_registration(p_request_id, 'approved', null);

  if not v_ok then
    raise exception 'این درخواست در انتظار بررسی نیست.';
  end if;

  select player_code into v_player_code
  from public.players
  where user_id = v_user_id;

  return jsonb_build_object(
    'success', true,
    'message', 'ثبت‌نام بازیکن با موفقیت تأیید شد.',
    'player_code', v_player_code,
    'user_id', v_user_id
  );
end;
$$;

-- Audit assignment/revocation changes using the existing audit trigger function.
drop trigger if exists audit_tournament_judges on public.tournament_judges;
create trigger audit_tournament_judges
after insert or update or delete on public.tournament_judges
for each row execute function public.log_score_changes();

drop trigger if exists audit_judge_assignments on public.judge_assignments;
create trigger audit_judge_assignments
after insert or update or delete on public.judge_assignments
for each row execute function public.log_score_changes();

revoke all on function public.get_eligible_tournament_judges(uuid) from public;
revoke all on function public.appoint_tournament_judge(uuid, uuid, text) from public;
revoke all on function public.assign_judge_to_match(uuid, uuid) from public;
revoke all on function public.revoke_judge_from_match(uuid, uuid) from public;
revoke all on function public.revoke_tournament_judge(uuid, uuid) from public;
revoke all on function public.get_judge_worklist() from public;
revoke all on function public.get_open_tournaments() from public;
revoke all on function public.review_registration(uuid, text, text) from public;
revoke all on function public.approve_player_registration(uuid) from public;

grant execute on function public.get_eligible_tournament_judges(uuid) to authenticated;
grant execute on function public.appoint_tournament_judge(uuid, uuid, text) to authenticated;
grant execute on function public.assign_judge_to_match(uuid, uuid) to authenticated;
grant execute on function public.revoke_judge_from_match(uuid, uuid) to authenticated;
grant execute on function public.revoke_tournament_judge(uuid, uuid) to authenticated;
grant execute on function public.get_judge_worklist() to authenticated;
grant execute on function public.get_open_tournaments() to anon, authenticated;
grant execute on function public.review_registration(uuid, text, text) to authenticated;
grant execute on function public.approve_player_registration(uuid) to authenticated;

commit;
