-- APEX ARENA: allow previously appointed judges to serve in additional tournaments.
-- Existing same-tournament approved-player appointment flow remains unchanged.
-- A judge's other tournament appointments are never modified by this migration.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_existing_tournament_judges(
  p_tournament_id uuid
)
RETURNS TABLE (
  user_id uuid,
  display_name text,
  player_code text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT DISTINCT
    p.id,
    p.display_name,
    pl.player_code
  FROM public.tournament_judges history
  JOIN public.profiles p
    ON p.id = history.judge_id
  JOIN public.players pl
    ON pl.user_id = p.id
  WHERE public.is_apex_manager()
    AND p.role = 'player'
    AND EXISTS (
      SELECT 1
      FROM public.tournament_judges prior
      WHERE prior.judge_id = p.id
    )
    -- Do not offer someone who is already an active judge in the destination.
    AND NOT EXISTS (
      SELECT 1
      FROM public.tournament_judges current_assignment
      WHERE current_assignment.tournament_id = p_tournament_id
        AND current_assignment.judge_id = p.id
        AND current_assignment.is_active = true
    )
    -- A person must not be both a player and a judge in the destination.
    AND NOT EXISTS (
      SELECT 1
      FROM public.tournament_memberships tm
      WHERE tm.tournament_id = p_tournament_id
        AND tm.user_id = p.id
        AND tm.status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.tournament_registration_requests r
      WHERE r.tournament_id = p_tournament_id
        AND r.user_id = p.id
        AND r.status = 'approved'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.match_players mp
      JOIN public.matches m
        ON m.id = mp.match_id
      JOIN public.players participant
        ON participant.id = mp.player_id
      WHERE m.tournament_id = p_tournament_id
        AND participant.user_id = p.id
    )
  ORDER BY p.display_name;
$$;

CREATE OR REPLACE FUNCTION public.appoint_existing_judge_to_tournament(
  p_tournament_id uuid,
  p_judge_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مجاز می‌تواند داور منصوب کند.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.tournaments t
    WHERE t.id = p_tournament_id
    FOR UPDATE
  ) THEN
    RAISE EXCEPTION 'تورنمنت مقصد پیدا نشد.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.tournament_judges history
    WHERE history.judge_id = p_judge_id
  ) THEN
    RAISE EXCEPTION 'این حساب سابقه انتصاب به‌عنوان داور ندارد.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    JOIN public.players pl ON pl.user_id = p.id
    WHERE p.id = p_judge_id
      AND p.role = 'player'
  ) THEN
    RAISE EXCEPTION 'حساب داور یا پروفایل بازیکن معتبر نیست.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.tournament_judges tj
    WHERE tj.tournament_id = p_tournament_id
      AND tj.judge_id = p_judge_id
      AND tj.is_active = true
  ) THEN
    RAISE EXCEPTION 'این شخص از قبل داور فعال همین تورنمنت است.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.tournament_memberships tm
    WHERE tm.tournament_id = p_tournament_id
      AND tm.user_id = p_judge_id
      AND tm.status = 'active'
  ) OR EXISTS (
    SELECT 1
    FROM public.tournament_registration_requests r
    WHERE r.tournament_id = p_tournament_id
      AND r.user_id = p_judge_id
      AND r.status = 'approved'
  ) OR EXISTS (
    SELECT 1
    FROM public.match_players mp
    JOIN public.matches m ON m.id = mp.match_id
    JOIN public.players pl ON pl.id = mp.player_id
    WHERE m.tournament_id = p_tournament_id
      AND pl.user_id = p_judge_id
  ) THEN
    RAISE EXCEPTION 'این شخص در تورنمنت مقصد سابقه یا عضویت فعال بازیکن دارد؛ ابتدا وضعیت بازیکنی او را تعیین تکلیف کنید.';
  END IF;

  INSERT INTO public.tournament_judges (
    tournament_id,
    judge_id,
    appointed_by,
    is_active,
    is_player_restored,
    created_at,
    revoked_by,
    revoked_at
  )
  VALUES (
    p_tournament_id,
    p_judge_id,
    auth.uid(),
    true,
    false,
    now(),
    NULL,
    NULL
  )
  ON CONFLICT (tournament_id, judge_id)
  DO UPDATE SET
    appointed_by = EXCLUDED.appointed_by,
    is_active = true,
    is_player_restored = false,
    created_at = now(),
    revoked_by = NULL,
    revoked_at = NULL
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'success', true,
    'appointment_id', v_id,
    'tournament_id', p_tournament_id,
    'judge_id', p_judge_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_existing_tournament_judges(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.appoint_existing_judge_to_tournament(uuid, uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_existing_tournament_judges(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.appoint_existing_judge_to_tournament(uuid, uuid) TO authenticated;

COMMIT;
