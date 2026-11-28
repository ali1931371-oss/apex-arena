-- APEX ARENA: allow an authenticated manager to serve as a judge in a tournament.
-- The manager receives only their own judge assignment; other judges' submissions remain immutable to them.
BEGIN;

CREATE OR REPLACE FUNCTION public.appoint_manager_as_tournament_judge(
  p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_appointment_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر اصلی یا مسئول مجاز می‌تواند خودش را به‌عنوان داور منصوب کند.';
  END IF;

  PERFORM 1
  FROM public.tournaments t
  WHERE t.id = p_tournament_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'تورنمنت انتخاب‌شده پیدا نشد.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.tournament_memberships tm
    WHERE tm.tournament_id = p_tournament_id
      AND tm.user_id = auth.uid()
      AND tm.status = 'active'
  ) OR EXISTS (
    SELECT 1
    FROM public.tournament_registration_requests r
    WHERE r.tournament_id = p_tournament_id
      AND r.user_id = auth.uid()
      AND r.status = 'approved'
  ) OR EXISTS (
    SELECT 1
    FROM public.match_players mp
    JOIN public.matches m ON m.id = mp.match_id
    JOIN public.players pl ON pl.id = mp.player_id
    WHERE m.tournament_id = p_tournament_id
      AND pl.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'مدیر در این تورنمنت سابقه یا عضویت بازیکن دارد و نمی‌تواند هم‌زمان داور همان تورنمنت باشد.';
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
    auth.uid(),
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
  RETURNING id INTO v_appointment_id;

  RETURN jsonb_build_object(
    'success', true,
    'appointment_id', v_appointment_id,
    'tournament_id', p_tournament_id,
    'judge_id', auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.appoint_manager_as_tournament_judge(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.appoint_manager_as_tournament_judge(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
