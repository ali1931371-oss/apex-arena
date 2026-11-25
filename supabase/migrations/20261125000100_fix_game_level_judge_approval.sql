-- APEX ARENA: approve only the players actually evaluated in this game.
-- The game-level manual scoring workflow stores stage/game participation in
-- judge_game_submissions; tournament capacity and other tournament members
-- must not be treated as players in every individual game.
-- Apply manually in Supabase SQL Editor only after reviewing the shared-project impact.

BEGIN;

CREATE OR REPLACE FUNCTION public.approve_judge_game_results(
  p_tournament_id uuid,
  p_stage_name text,
  p_game_number integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_required integer;
  v_active integer;
  v_game_player_count integer;
  v_expected integer;
  v_updated integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مسابقه می‌تواند نتیجه بازی را تأیید کند.';
  END IF;

  IF p_stage_name IS NULL OR length(btrim(p_stage_name)) NOT BETWEEN 1 AND 100
     OR p_game_number IS NULL OR p_game_number NOT BETWEEN 1 AND 999 THEN
    RAISE EXCEPTION 'مرحله یا شماره بازی معتبر نیست.';
  END IF;

  PERFORM 1 FROM public.tournaments WHERE id = p_tournament_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'تورنمنت پیدا نشد.'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.judge_game_game_approvals a
    WHERE a.tournament_id = p_tournament_id
      AND a.stage_key = lower(btrim(p_stage_name))
      AND a.game_number = p_game_number
  ) THEN
    RAISE EXCEPTION 'این بازی قبلاً تأیید و منتشر شده است.';
  END IF;

  SELECT required_judge_count INTO v_required
  FROM public.tournament_judging_settings
  WHERE tournament_id = p_tournament_id;

  SELECT count(*)::integer INTO v_active
  FROM public.tournament_judges
  WHERE tournament_id = p_tournament_id AND is_active = true;

  IF v_required IS NULL OR v_active <> v_required THEN
    RAISE EXCEPTION 'تعداد داوران فعال با تعداد تعیین‌شده تورنمنت مطابقت ندارد.';
  END IF;

  -- Determine this game's roster from finalized evaluations for this exact
  -- tournament + stage + game. Do not count every active tournament member:
  -- some members may not have participated in this particular game.
  SELECT count(DISTINCT s.player_id)::integer
  INTO v_game_player_count
  FROM public.judge_game_submissions s
  JOIN public.tournament_memberships tm
    ON tm.tournament_id = s.tournament_id
   AND tm.player_id = s.player_id
   AND tm.status = 'active'
  WHERE s.tournament_id = p_tournament_id
    AND s.stage_key = lower(btrim(p_stage_name))
    AND s.game_number = p_game_number
    AND s.status = 'pending_review';

  IF v_game_player_count = 0 THEN
    RAISE EXCEPTION 'برای این بازی هیچ ارزیابی نهایی و معتبری ثبت نشده است.';
  END IF;

  -- Required submissions are based on players in this game multiplied by
  -- the configured judge slots, never on tournament registration capacity.
  v_expected := v_game_player_count * v_required;

  -- Every player represented in this game's finalized evaluations must have
  -- one finalized submission in every active judge slot. A manager replacement
  -- fills the absent judge's slot through replacement_for_judge_id.
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT s.player_id
      FROM public.judge_game_submissions s
      JOIN public.tournament_memberships tm
        ON tm.tournament_id = s.tournament_id
       AND tm.player_id = s.player_id
       AND tm.status = 'active'
      WHERE s.tournament_id = p_tournament_id
        AND s.stage_key = lower(btrim(p_stage_name))
        AND s.game_number = p_game_number
        AND s.status = 'pending_review'
    ) game_players
    CROSS JOIN public.tournament_judges tj
    WHERE tj.tournament_id = p_tournament_id
      AND tj.is_active = true
      AND NOT EXISTS (
        SELECT 1
        FROM public.judge_game_submissions s
        WHERE s.tournament_id = p_tournament_id
          AND s.stage_key = lower(btrim(p_stage_name))
          AND s.game_number = p_game_number
          AND s.player_id = game_players.player_id
          AND COALESCE(s.replacement_for_judge_id, s.judge_id) = tj.judge_id
          AND s.status = 'pending_review'
      )
  ) THEN
    RAISE EXCEPTION 'برای همه بازیکنان این بازی باید هر داور فعال یک ارزیابی نهایی ارسال کرده باشد. جای خالی داوران را تکمیل کنید.';
  END IF;

  SELECT count(*)::integer INTO v_updated
  FROM public.judge_game_submissions s
  JOIN public.tournament_memberships tm
    ON tm.tournament_id = s.tournament_id
   AND tm.player_id = s.player_id
   AND tm.status = 'active'
  WHERE s.tournament_id = p_tournament_id
    AND s.stage_key = lower(btrim(p_stage_name))
    AND s.game_number = p_game_number
    AND s.status = 'pending_review';

  IF v_updated <> v_expected THEN
    RAISE EXCEPTION 'تعداد ارزیابی‌های نهایی (%) با تعداد موردنیاز برای بازیکنان همین بازی (%) برابر نیست.', v_updated, v_expected;
  END IF;

  INSERT INTO public.judge_game_game_approvals
    (tournament_id, stage_name, game_number, approved_by)
  VALUES
    (p_tournament_id, btrim(p_stage_name), p_game_number, auth.uid());

  UPDATE public.judge_game_submissions
  SET status = 'approved',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = 'تأیید گروهی بازی و انتشار میانگین',
      updated_at = now()
  WHERE tournament_id = p_tournament_id
    AND stage_key = lower(btrim(p_stage_name))
    AND game_number = p_game_number
    AND status = 'pending_review';

  RETURN jsonb_build_object(
    'success', true,
    'approved_count', v_updated,
    'expected_count', v_expected,
    'game_player_count', v_game_player_count,
    'required_judge_count', v_required,
    'publication_mode', 'average'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.approve_judge_game_results(uuid, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_judge_game_results(uuid, text, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
