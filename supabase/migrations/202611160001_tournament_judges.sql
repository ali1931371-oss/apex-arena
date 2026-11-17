-- APEX ARENA: tournament-scoped judge management
-- Apply manually in Supabase SQL Editor after reviewing this migration.
-- This migration does NOT change profiles.role: a player can be a judge in one
-- tournament and remain a player in another tournament.
BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_judges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  judge_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  appointed_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  is_active boolean NOT NULL DEFAULT true,
  is_player_restored boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  revoked_at timestamptz,
  UNIQUE (tournament_id, judge_id),
  CONSTRAINT tournament_judges_revocation_check
    CHECK ((is_active AND revoked_at IS NULL) OR (NOT is_active AND revoked_at IS NOT NULL)),
  CONSTRAINT tournament_judges_restoration_check
    CHECK (NOT (is_active AND is_player_restored))
);

ALTER TABLE public.tournament_judges
  ADD COLUMN IF NOT EXISTS is_player_restored boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS tournament_judges_active_lookup
  ON public.tournament_judges (tournament_id, judge_id)
  WHERE is_active = true;

ALTER TABLE public.tournament_judges ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.tournament_judges TO authenticated;

CREATE OR REPLACE FUNCTION public.is_apex_manager()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = (SELECT auth.uid())
      AND p.role IN ('admin', 'manager')
  );
$$;

CREATE OR REPLACE FUNCTION public.is_active_tournament_judge(p_tournament_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.tournament_judges tj
    WHERE tj.tournament_id = p_tournament_id
      AND tj.judge_id = (SELECT auth.uid())
      AND tj.is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION public.is_assigned_tournament_judge(p_match_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.judge_assignments ja
    JOIN public.matches m ON m.id = ja.match_id
    JOIN public.tournament_judges tj
      ON tj.tournament_id = m.tournament_id
     AND tj.judge_id = ja.judge_id
     AND tj.is_active = true
    WHERE ja.match_id = p_match_id
      AND ja.judge_id = (SELECT auth.uid())
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_apex_manager() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_tournament_judge(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_assigned_tournament_judge(uuid) TO authenticated;

DROP POLICY IF EXISTS tournament_judges_read_own_or_manager ON public.tournament_judges;
CREATE POLICY tournament_judges_read_own_or_manager
ON public.tournament_judges
FOR SELECT
TO authenticated
USING (judge_id = (SELECT auth.uid()) OR public.is_apex_manager());

DROP POLICY IF EXISTS judge_assignments_read_own ON public.judge_assignments;
CREATE POLICY judge_assignments_read_own
ON public.judge_assignments
FOR SELECT
TO authenticated
USING (judge_id = (SELECT auth.uid()) OR public.is_apex_manager());

CREATE OR REPLACE FUNCTION public.appoint_tournament_judge(
  p_tournament_id uuid,
  p_judge_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مجاز می‌تواند داور منصوب کند.';
  END IF;

  SELECT p.role INTO v_role
  FROM public.profiles p
  WHERE p.id = p_judge_id;

  IF v_role IS DISTINCT FROM 'player' THEN
    RAISE EXCEPTION 'فقط حساب دارای نقش بازیکن قابل انتصاب به داوری است.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.players pl WHERE pl.user_id = p_judge_id
  ) THEN
    RAISE EXCEPTION 'برای این حساب، پروفایل بازیکن تأییدشده وجود ندارد.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.tournament_registration_requests r
    WHERE r.tournament_id = p_tournament_id
      AND r.user_id = p_judge_id
      AND r.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'این حساب بازیکن تأییدشده این تورنمنت نیست.';
  END IF;

  INSERT INTO public.tournament_judges (
    tournament_id, judge_id, appointed_by, is_active, is_player_restored,
    created_at, revoked_by, revoked_at
  )
  VALUES (p_tournament_id, p_judge_id, auth.uid(), true, false, now(), NULL, NULL)
  ON CONFLICT (tournament_id, judge_id)
  DO UPDATE SET
    appointed_by = EXCLUDED.appointed_by,
    is_active = true,
    is_player_restored = false,
    created_at = now(),
    revoked_by = NULL,
    revoked_at = NULL
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'appointment_id', v_id);
END;
$$;

DROP FUNCTION IF EXISTS public.revoke_tournament_judge(uuid, uuid);

CREATE OR REPLACE FUNCTION public.revoke_tournament_judge(
  p_tournament_id uuid,
  p_judge_id uuid,
  p_restore_as_player boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_settings record;
  v_player_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مجاز می‌تواند انتصاب داور را لغو کند.';
  END IF;

  IF p_restore_as_player THEN
    SELECT s.* INTO v_settings
    FROM public.tournament_registration_settings s
    WHERE s.tournament_id = p_tournament_id
    FOR UPDATE;

    IF FOUND AND v_settings.registration_open THEN
      SELECT count(DISTINCT r.user_id)::integer INTO v_player_count
      FROM public.tournament_registration_requests r
      JOIN public.profiles p ON p.id = r.user_id AND p.role = 'player'
      JOIN public.players pl ON pl.user_id = r.user_id
      WHERE r.tournament_id = p_tournament_id
        AND r.status = 'approved'
        AND NOT EXISTS (
          SELECT 1 FROM public.tournament_judges tj
          WHERE tj.tournament_id = r.tournament_id
            AND tj.judge_id = r.user_id
            AND tj.is_player_restored = false
        );

      IF v_player_count >= v_settings.max_players THEN
        RAISE EXCEPTION 'ظرفیت بازیکنان تکمیل است؛ بازگردانی به بازیکن ممکن نیست.';
      END IF;
    END IF;
  END IF;

  UPDATE public.tournament_judges
  SET is_active = false,
      is_player_restored = p_restore_as_player,
      revoked_by = auth.uid(),
      revoked_at = now()
  WHERE tournament_id = p_tournament_id
    AND judge_id = p_judge_id
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  DELETE FROM public.judge_assignments ja
  USING public.matches m
  WHERE ja.match_id = m.id
    AND m.tournament_id = p_tournament_id
    AND ja.judge_id = p_judge_id;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_judge_to_match(
  p_match_id uuid,
  p_judge_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tournament_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مجاز می‌تواند داور مسابقه تعیین کند.';
  END IF;

  SELECT m.tournament_id INTO v_tournament_id
  FROM public.matches m
  WHERE m.id = p_match_id
  FOR UPDATE;

  IF v_tournament_id IS NULL THEN
    RAISE EXCEPTION 'مسابقه پیدا نشد.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.tournament_judges tj
    WHERE tj.tournament_id = v_tournament_id
      AND tj.judge_id = p_judge_id
      AND tj.is_active = true
  ) THEN
    RAISE EXCEPTION 'این شخص برای این تورنمنت داور فعال نیست.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.match_players mp
    JOIN public.players pl ON pl.id = mp.player_id
    WHERE mp.match_id = p_match_id
      AND pl.user_id = p_judge_id
  ) THEN
    RAISE EXCEPTION 'این شخص در همین مسابقه بازیکن است و نمی‌تواند هم‌زمان داور باشد.';
  END IF;

  INSERT INTO public.judge_assignments (match_id, judge_id)
  VALUES (p_match_id, p_judge_id)
  ON CONFLICT (match_id, judge_id) DO NOTHING;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.unassign_judge_from_match(
  p_match_id uuid,
  p_judge_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مجاز می‌تواند انتساب داور را لغو کند.';
  END IF;

  DELETE FROM public.judge_assignments
  WHERE match_id = p_match_id
    AND judge_id = p_judge_id;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.appoint_tournament_judge(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_tournament_judge(uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assign_judge_to_match(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unassign_judge_from_match(uuid, uuid) TO authenticated;

GRANT SELECT ON public.judge_assignments TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.score_submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.score_items TO authenticated;

-- A tournament judge must never be inserted as a participant in that tournament.
CREATE OR REPLACE FUNCTION public.prevent_tournament_judge_as_match_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.matches m
    JOIN public.players pl ON pl.id = NEW.player_id
    JOIN public.tournament_judges tj
      ON tj.tournament_id = m.tournament_id
     AND tj.judge_id = pl.user_id
     AND tj.is_active = true
    WHERE m.id = NEW.match_id
  ) THEN
    RAISE EXCEPTION 'داور فعال این تورنمنت نمی‌تواند شرکت‌کننده مسابقه باشد.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_tournament_judge_match_player ON public.match_players;
CREATE TRIGGER prevent_tournament_judge_match_player
BEFORE INSERT OR UPDATE OF match_id, player_id
ON public.match_players
FOR EACH ROW
EXECUTE FUNCTION public.prevent_tournament_judge_as_match_player();

-- Manager-only read APIs keep private profile fields out of the browser.
CREATE OR REPLACE FUNCTION public.get_manageable_tournaments()
RETURNS TABLE(tournament_id uuid, tournament_name text, tournament_status text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT t.id, t.name, t.status
  FROM public.tournaments t
  WHERE public.is_apex_manager()
  ORDER BY t.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.get_tournament_judge_candidates(p_tournament_id uuid)
RETURNS TABLE(user_id uuid, display_name text, player_code text, username text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.id, p.display_name, pl.player_code, p.username
  FROM public.profiles p
  JOIN public.players pl ON pl.user_id = p.id
  WHERE public.is_apex_manager()
    AND p.role = 'player'
    AND EXISTS (
      SELECT 1 FROM public.tournament_registration_requests r
      WHERE r.user_id = p.id
        AND r.tournament_id = p_tournament_id
        AND r.status = 'approved'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.tournament_judges tj
      WHERE tj.tournament_id = p_tournament_id
        AND tj.judge_id = p.id
        AND tj.is_player_restored = false
    )
  ORDER BY p.display_name;
$$;

CREATE OR REPLACE FUNCTION public.get_tournament_judges(p_tournament_id uuid)
RETURNS TABLE(
  user_id uuid,
  display_name text,
  player_code text,
  is_active boolean,
  is_player_restored boolean,
  appointed_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.id, p.display_name, pl.player_code, tj.is_active, tj.is_player_restored, tj.created_at
  FROM public.tournament_judges tj
  JOIN public.profiles p ON p.id = tj.judge_id
  LEFT JOIN public.players pl ON pl.user_id = p.id
  WHERE public.is_apex_manager()
    AND tj.tournament_id = p_tournament_id
  ORDER BY tj.is_active DESC, p.display_name;
$$;

CREATE OR REPLACE FUNCTION public.get_tournament_matches(p_tournament_id uuid)
RETURNS TABLE(
  match_id uuid,
  match_number integer,
  match_status text,
  stage_id uuid,
  group_id uuid,
  assigned_judges jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    m.id,
    m.match_number,
    m.status,
    m.stage_id,
    m.group_id,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', p.id,
        'display_name', p.display_name
      ) ORDER BY p.display_name)
      FROM public.judge_assignments ja
      JOIN public.profiles p ON p.id = ja.judge_id
      JOIN public.tournament_judges tj
        ON tj.tournament_id = m.tournament_id
       AND tj.judge_id = ja.judge_id
       AND tj.is_active = true
      WHERE ja.match_id = m.id
    ), '[]'::jsonb)
  FROM public.matches m
  WHERE public.is_apex_manager()
    AND m.tournament_id = p_tournament_id
  ORDER BY m.match_number, m.created_at;
$$;

CREATE OR REPLACE FUNCTION public.get_my_judge_assignments()
RETURNS TABLE(
  match_id uuid,
  tournament_id uuid,
  tournament_name text,
  match_number integer,
  match_status text,
  stage_id uuid,
  group_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT m.id, m.tournament_id, t.name, m.match_number, m.status, m.stage_id, m.group_id
  FROM public.judge_assignments ja
  JOIN public.matches m ON m.id = ja.match_id
  JOIN public.tournaments t ON t.id = m.tournament_id
  JOIN public.tournament_judges tj
    ON tj.tournament_id = m.tournament_id
   AND tj.judge_id = ja.judge_id
   AND tj.is_active = true
  WHERE ja.judge_id = (SELECT auth.uid())
  ORDER BY t.name, m.match_number;
$$;

CREATE OR REPLACE FUNCTION public.get_judge_match_details(p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_assigned_tournament_judge(p_match_id) THEN
    RAISE EXCEPTION 'شما داور این مسابقه نیستید.';
  END IF;

  SELECT jsonb_build_object(
    'match', jsonb_build_object(
      'id', m.id,
      'tournament_id', m.tournament_id,
      'match_number', m.match_number,
      'status', m.status,
      'stage_id', m.stage_id,
      'group_id', m.group_id
    ),
    'players', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'player_id', pl.id,
        'display_name', pl.display_name,
        'player_code', pl.player_code,
        'audio_player_id', pl.audio_player_id
      ) ORDER BY mp.seat_number)
      FROM public.match_players mp
      JOIN public.players pl ON pl.id = mp.player_id
      WHERE mp.match_id = m.id
        AND NOT EXISTS (
          SELECT 1 FROM public.tournament_judges tj
          WHERE tj.tournament_id = m.tournament_id
            AND tj.judge_id = pl.user_id
            AND tj.is_player_restored = false
        )
    ), '[]'::jsonb),
    'criteria', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', tc.id,
        'criterion_name', tc.criterion_name,
        'description', tc.description,
        'min_points', tc.min_points,
        'max_points', tc.max_points,
        'weight', tc.weight,
        'score_type', tc.score_type,
        'calculation_type', tc.calculation_type,
        'aggregation_method', tc.aggregation_method,
        'display_order', tc.display_order
      ) ORDER BY tc.display_order)
      FROM public.tournament_criteria tc
      WHERE tc.tournament_id = m.tournament_id
        AND tc.is_active = true
    ), '[]'::jsonb),
    'submissions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', ss.id,
        'player_id', ss.player_id,
        'status', ss.status,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'criterion_id', si.criterion_id,
            'raw_points', si.raw_points,
            'notes', si.notes
          ))
          FROM public.score_items si
          WHERE si.submission_id = ss.id
        ), '[]'::jsonb)
      ))
      FROM public.score_submissions ss
      WHERE ss.match_id = m.id
        AND ss.judge_id = auth.uid()
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.matches m
  WHERE m.id = p_match_id;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_manageable_tournaments() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_tournament_judge_candidates(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_tournament_judges(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_tournament_matches(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_judge_assignments() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_judge_match_details(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.is_tournament_judge_player(
  p_tournament_id uuid,
  p_player_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.players pl
    JOIN public.tournament_judges tj
      ON tj.judge_id = pl.user_id
     AND tj.tournament_id = p_tournament_id
     AND tj.is_active = true
    WHERE pl.id = p_player_id
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_tournament_judge_player(uuid, uuid) TO anon, authenticated;

-- Hide appointed tournament judges from the public participant roster.
DROP POLICY IF EXISTS public_view_match_players ON public.match_players;
CREATE POLICY public_view_match_players
ON public.match_players
FOR SELECT
TO anon, authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.matches m
    JOIN public.tournaments t ON t.id = m.tournament_id
    WHERE m.id = match_players.match_id
      AND m.status <> 'cancelled'
      AND t.status IN ('registration', 'active', 'completed')
      AND NOT public.is_tournament_judge_player(m.tournament_id, match_players.player_id)
  )
);

-- Judge can read only their own submissions and create submissions for assigned matches.
DROP POLICY IF EXISTS judge_read_own_score_submissions ON public.score_submissions;
CREATE POLICY judge_read_own_score_submissions
ON public.score_submissions
FOR SELECT
TO authenticated
USING (judge_id = (SELECT auth.uid()) OR public.is_apex_manager());

DROP POLICY IF EXISTS judge_insert_assigned_score_submission ON public.score_submissions;
CREATE POLICY judge_insert_assigned_score_submission
ON public.score_submissions
FOR INSERT
TO authenticated
WITH CHECK (
  judge_id = (SELECT auth.uid())
  AND status = 'draft'
  AND public.is_assigned_tournament_judge(match_id)
  AND EXISTS (
    SELECT 1
    FROM public.match_players mp
    WHERE mp.match_id = score_submissions.match_id
      AND mp.player_id = score_submissions.player_id
  )
);

DROP POLICY IF EXISTS judge_update_own_draft_score_submission ON public.score_submissions;
CREATE POLICY judge_update_own_draft_score_submission
ON public.score_submissions
FOR UPDATE
TO authenticated
USING (
  judge_id = (SELECT auth.uid())
  AND status = 'draft'
  AND public.is_assigned_tournament_judge(match_id)
)
WITH CHECK (
  judge_id = (SELECT auth.uid())
  AND status IN ('draft', 'submitted')
  AND public.is_assigned_tournament_judge(match_id)
  AND EXISTS (
    SELECT 1
    FROM public.match_players mp
    WHERE mp.match_id = score_submissions.match_id
      AND mp.player_id = score_submissions.player_id
  )
);

DROP POLICY IF EXISTS judge_read_own_score_items ON public.score_items;
CREATE POLICY judge_read_own_score_items
ON public.score_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.score_submissions ss
    WHERE ss.id = score_items.submission_id
      AND (ss.judge_id = (SELECT auth.uid()) OR public.is_apex_manager())
  )
);

DROP POLICY IF EXISTS judge_insert_own_draft_score_items ON public.score_items;
CREATE POLICY judge_insert_own_draft_score_items
ON public.score_items
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.score_submissions ss
    JOIN public.matches m ON m.id = ss.match_id
    JOIN public.tournament_criteria tc
      ON tc.id = score_items.criterion_id
     AND tc.tournament_id = m.tournament_id
    WHERE ss.id = score_items.submission_id
      AND ss.judge_id = (SELECT auth.uid())
      AND ss.status = 'draft'
      AND public.is_assigned_tournament_judge(ss.match_id)
      AND tc.is_active = true
      AND score_items.raw_points BETWEEN tc.min_points AND tc.max_points
      AND EXISTS (
        SELECT 1 FROM public.matches mx
        WHERE mx.id = ss.match_id
          AND mx.status IN ('live', 'submitted')
      )
  )
);

DROP POLICY IF EXISTS judge_update_own_draft_score_items ON public.score_items;
CREATE POLICY judge_update_own_draft_score_items
ON public.score_items
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.score_submissions ss
    WHERE ss.id = score_items.submission_id
      AND ss.judge_id = (SELECT auth.uid())
      AND ss.status = 'draft'
      AND public.is_assigned_tournament_judge(ss.match_id)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.score_submissions ss
    JOIN public.matches m ON m.id = ss.match_id
    JOIN public.tournament_criteria tc
      ON tc.id = score_items.criterion_id
     AND tc.tournament_id = m.tournament_id
    WHERE ss.id = score_items.submission_id
      AND ss.judge_id = (SELECT auth.uid())
      AND ss.status = 'draft'
      AND public.is_assigned_tournament_judge(ss.match_id)
      AND tc.is_active = true
      AND score_items.raw_points BETWEEN tc.min_points AND tc.max_points
  )
);

DROP POLICY IF EXISTS judge_delete_own_draft_score_items ON public.score_items;
CREATE POLICY judge_delete_own_draft_score_items
ON public.score_items
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.score_submissions ss
    WHERE ss.id = score_items.submission_id
      AND ss.judge_id = (SELECT auth.uid())
      AND ss.status = 'draft'
      AND public.is_assigned_tournament_judge(ss.match_id)
  )
);

-- Keep public capacity accurate: count distinct approved players, never appointed judges.
CREATE OR REPLACE FUNCTION public.get_open_tournaments()
RETURNS TABLE(
  tournament_id uuid,
  tournament_name text,
  tournament_slug text,
  tournament_description text,
  max_players integer,
  approved_players bigint,
  available_slots integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    t.id,
    t.name,
    t.slug,
    t.description,
    s.max_players,
    (
      SELECT count(DISTINCT r.user_id)
      FROM public.tournament_registration_requests r
      JOIN public.profiles p ON p.id = r.user_id AND p.role = 'player'
      JOIN public.players pl ON pl.user_id = r.user_id
      WHERE r.tournament_id = t.id
        AND r.status = 'approved'
        AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_judges tj
          WHERE tj.tournament_id = t.id
            AND tj.judge_id = r.user_id
            AND tj.is_player_restored = false
        )
    ),
    greatest(
      s.max_players - (
        SELECT count(DISTINCT r.user_id)::integer
        FROM public.tournament_registration_requests r
        JOIN public.profiles p ON p.id = r.user_id AND p.role = 'player'
        JOIN public.players pl ON pl.user_id = r.user_id
        WHERE r.tournament_id = t.id
          AND r.status = 'approved'
          AND NOT EXISTS (
            SELECT 1
            FROM public.tournament_judges tj
            WHERE tj.tournament_id = t.id
              AND tj.judge_id = r.user_id
              AND tj.is_player_restored = false
          )
      ),
      0
    )
  FROM public.tournaments t
  JOIN public.tournament_registration_settings s ON s.tournament_id = t.id
  WHERE t.status = 'registration'
    AND s.registration_open = true
  ORDER BY t.created_at DESC;
$$;

-- Ensure the legacy approval function cannot create a player record for a judge.
CREATE OR REPLACE FUNCTION public.approve_player_registration(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_request record;
  v_actor_role text;
  v_display_name text;
  v_player_code text;
  v_settings record;
  v_approved_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'ابتدا باید وارد حساب کاربری شوید.';
  END IF;

  SELECT p.role INTO v_actor_role
  FROM public.profiles p
  WHERE p.id = auth.uid();

  IF v_actor_role IS NULL OR v_actor_role NOT IN ('admin', 'manager') THEN
    RAISE EXCEPTION 'شما اجازه تأیید ثبت‌نام را ندارید.';
  END IF;

  SELECT * INTO v_request
  FROM public.tournament_registration_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'درخواست ثبت‌نام پیدا نشد.';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'این درخواست قبلاً بررسی شده است.';
  END IF;

  SELECT s.* INTO v_settings
  FROM public.tournament_registration_settings s
  WHERE s.tournament_id = v_request.tournament_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'تنظیمات ثبت‌نام این تورنمنت وجود ندارد.';
  END IF;

  IF NOT v_settings.registration_open THEN
    RAISE EXCEPTION 'ثبت‌نام این تورنمنت بسته است.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.tournaments t
    WHERE t.id = v_request.tournament_id
      AND t.status = 'registration'
  ) THEN
    RAISE EXCEPTION 'وضعیت تورنمنت اجازه تأیید ثبت‌نام نمی‌دهد.';
  END IF;

  SELECT count(DISTINCT r.user_id)::integer INTO v_approved_count
  FROM public.tournament_registration_requests r
  JOIN public.profiles p ON p.id = r.user_id AND p.role = 'player'
  JOIN public.players pl ON pl.user_id = r.user_id
  WHERE r.tournament_id = v_request.tournament_id
    AND r.status = 'approved'
    AND NOT EXISTS (
      SELECT 1 FROM public.tournament_judges tj
      WHERE tj.tournament_id = r.tournament_id
        AND tj.judge_id = r.user_id
        AND tj.is_active = true
    );

  IF v_approved_count >= v_settings.max_players THEN
    RAISE EXCEPTION 'ظرفیت تورنمنت تکمیل شده است.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_request.user_id
      AND p.role <> 'player'
  ) THEN
    RAISE EXCEPTION 'این حساب نقش بازیکن ندارد و قابل تأیید به‌عنوان بازیکن نیست.';
  END IF;

  v_display_name := coalesce(
    nullif(trim(v_request.full_name), ''),
    nullif(trim(v_request.requested_display_name), '')
  );

  IF v_display_name IS NULL THEN
    RAISE EXCEPTION 'نام بازیکن ثبت نشده است.';
  END IF;

  INSERT INTO public.profiles (id, display_name, role, username, phone)
  VALUES (v_request.user_id, v_display_name, 'player', v_request.username, v_request.phone)
  ON CONFLICT (id) DO UPDATE
  SET display_name = EXCLUDED.display_name,
      username = coalesce(EXCLUDED.username, public.profiles.username),
      phone = coalesce(EXCLUDED.phone, public.profiles.phone)
  WHERE public.profiles.role = 'player';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'پروفایل موجود است و نقش آن قابل تبدیل به بازیکن نیست.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.players pl WHERE pl.user_id = v_request.user_id
  ) THEN
    v_player_code := 'APX-' || nextval('public.player_code_seq')::text;

    INSERT INTO public.players (user_id, player_code, display_name, audio_player_id)
    VALUES (v_request.user_id, v_player_code, v_display_name, v_request.audio_player_id);
  ELSE
    SELECT pl.player_code INTO v_player_code
    FROM public.players pl
    WHERE pl.user_id = v_request.user_id;
  END IF;

  UPDATE public.tournament_registration_requests
  SET status = 'approved',
      reviewed_by = auth.uid(),
      reviewed_at = now()
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'ثبت‌نام بازیکن با موفقیت تأیید شد.',
    'player_code', v_player_code,
    'user_id', v_request.user_id
  );
END;
$$;

-- Keep the legacy registration-review RPC on the same safe approval path.
CREATE OR REPLACE FUNCTION public.review_registration(
  p_request_id uuid,
  p_decision text,
  p_note text DEFAULT NULL::text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_request public.tournament_registration_requests%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'اجازه انجام این عملیات را ندارید.';
  END IF;

  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'وضعیت باید approved یا rejected باشد.';
  END IF;

  SELECT * INTO v_request
  FROM public.tournament_registration_requests
  WHERE id = p_request_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF p_decision = 'approved' THEN
    PERFORM public.approve_player_registration(p_request_id);
  ELSE
    UPDATE public.tournament_registration_requests
    SET status = 'rejected',
        reviewed_by = auth.uid(),
        review_note = p_note,
        reviewed_at = now()
    WHERE id = p_request_id;
  END IF;

  RETURN true;
END;
$$;

-- Audit appointment and match-assignment changes using the existing audit function.
DROP TRIGGER IF EXISTS audit_tournament_judges ON public.tournament_judges;
CREATE TRIGGER audit_tournament_judges
AFTER INSERT OR UPDATE OR DELETE ON public.tournament_judges
FOR EACH ROW EXECUTE FUNCTION public.log_score_changes();

DROP TRIGGER IF EXISTS audit_judge_assignments ON public.judge_assignments;
CREATE TRIGGER audit_judge_assignments
AFTER INSERT OR UPDATE OR DELETE ON public.judge_assignments
FOR EACH ROW EXECUTE FUNCTION public.log_score_changes();

COMMIT;
