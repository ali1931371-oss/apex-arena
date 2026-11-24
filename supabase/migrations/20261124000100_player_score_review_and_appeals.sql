-- APEX ARENA: private player score review and judge appeals.
-- Access is exclusively through SECURITY DEFINER RPCs; no direct table grants.
BEGIN;

CREATE TABLE IF NOT EXISTS public.player_score_appeals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id uuid NOT NULL REFERENCES public.judge_game_submissions(id) ON DELETE CASCADE,
  score_item_id uuid NOT NULL REFERENCES public.judge_game_score_items(id) ON DELETE CASCADE,
  player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  judge_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  message text NOT NULL CHECK (length(btrim(message)) BETWEEN 5 AND 2000),
  judge_reply text CHECK (judge_reply IS NULL OR length(btrim(judge_reply)) BETWEEN 1 AND 2000),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered')),
  created_at timestamptz NOT NULL DEFAULT now(),
  answered_at timestamptz,
  UNIQUE (score_item_id, player_id),
  CHECK ((status = 'open' AND judge_reply IS NULL AND answered_at IS NULL)
      OR (status = 'answered' AND judge_reply IS NOT NULL AND answered_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS player_score_appeals_player_idx
  ON public.player_score_appeals (player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS player_score_appeals_judge_idx
  ON public.player_score_appeals (judge_id, status, created_at DESC);

ALTER TABLE public.player_score_appeals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.player_score_appeals FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_my_player_score_reviews()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_player_id uuid; v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'ابتدا وارد حساب APEX ARENA شوید.'; END IF;
  SELECT pl.id INTO v_player_id
  FROM public.players pl
  WHERE pl.user_id = auth.uid()
  ORDER BY pl.created_at DESC LIMIT 1;
  IF v_player_id IS NULL THEN
    RETURN jsonb_build_object('player', NULL, 'games', '[]'::jsonb);
  END IF;

  SELECT jsonb_build_object(
    'player', jsonb_build_object('id', pl.id, 'name', pl.display_name, 'code', pl.player_code),
    'games', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'submission_id', s.id, 'tournament_id', s.tournament_id,
        'tournament_name', t.name, 'stage_name', s.stage_name,
        'game_number', s.game_number, 'side', s.side, 'role_name', s.role_name,
        'judge_id', s.judge_id, 'judge_name', COALESCE(pr.display_name, pr.username, 'داور'),
        'submitted_at', s.submitted_at,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'score_item_id', si.id, 'criterion_id', tc.id,
            'criterion_name', tc.criterion_name, 'criterion_group', tc.criterion_group,
            'points', si.raw_points, 'notes', si.notes,
            'appeal', CASE WHEN a.id IS NULL THEN NULL ELSE jsonb_build_object(
              'id',a.id,'message',a.message,'reply',a.judge_reply,'status',a.status,
              'created_at',a.created_at,'answered_at',a.answered_at) END
          ) ORDER BY tc.display_order)
          FROM public.judge_game_score_items si
          JOIN public.tournament_criteria tc ON tc.id = si.criterion_id
          LEFT JOIN public.player_score_appeals a
            ON a.score_item_id = si.id AND a.player_id = v_player_id
          WHERE si.submission_id = s.id
        ), '[]'::jsonb)
      ) ORDER BY t.name, s.stage_name, s.game_number, pr.display_name)
      FROM public.judge_game_submissions s
      JOIN public.tournaments t ON t.id = s.tournament_id
      JOIN public.profiles pr ON pr.id = s.judge_id
      WHERE s.player_id = v_player_id AND s.status = 'approved'
    ), '[]'::jsonb)
  ) INTO v_result
  FROM public.players pl WHERE pl.id = v_player_id;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_player_score_appeal(
  p_score_item_id uuid, p_message text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_player_id uuid; v_submission_id uuid; v_judge_id uuid; v_appeal_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'ابتدا وارد حساب شوید.'; END IF;
  IF p_message IS NULL OR length(btrim(p_message)) NOT BETWEEN 5 AND 2000 THEN
    RAISE EXCEPTION 'متن اعتراض باید بین ۵ تا ۲۰۰۰ نویسه باشد.';
  END IF;
  SELECT pl.id INTO v_player_id FROM public.players pl
  WHERE pl.user_id = auth.uid() ORDER BY pl.created_at DESC LIMIT 1;
  IF v_player_id IS NULL THEN RAISE EXCEPTION 'برای این حساب، پرونده بازیکنی پیدا نشد.'; END IF;

  SELECT s.id, s.judge_id INTO v_submission_id, v_judge_id
  FROM public.judge_game_score_items si
  JOIN public.judge_game_submissions s ON s.id = si.submission_id
  WHERE si.id = p_score_item_id AND s.player_id = v_player_id AND s.status = 'approved';
  IF NOT FOUND THEN RAISE EXCEPTION 'این نمره متعلق به پرونده تأییدشده شما نیست.'; END IF;

  INSERT INTO public.player_score_appeals
    (submission_id, score_item_id, player_id, judge_id, message)
  VALUES (v_submission_id, p_score_item_id, v_player_id, v_judge_id, btrim(p_message))
  RETURNING id INTO v_appeal_id;
  RETURN jsonb_build_object('success',true,'appeal_id',v_appeal_id);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'برای این معیار قبلاً اعتراض ثبت کرده‌اید.';
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_judge_score_appeals()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'ابتدا وارد حساب داوری شوید.'; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'appeal_id',a.id,'message',a.message,'reply',a.judge_reply,'status',a.status,
    'created_at',a.created_at,'player_name',pl.display_name,
    'tournament_name',t.name,'stage_name',s.stage_name,'game_number',s.game_number,
    'criterion_name',tc.criterion_name,'points',si.raw_points
  ) ORDER BY a.created_at DESC),'[]'::jsonb)
  INTO v_result
  FROM public.player_score_appeals a
  JOIN public.judge_game_submissions s ON s.id=a.submission_id
  JOIN public.players pl ON pl.id=a.player_id
  JOIN public.tournaments t ON t.id=s.tournament_id
  JOIN public.judge_game_score_items si ON si.id=a.score_item_id
  JOIN public.tournament_criteria tc ON tc.id=si.criterion_id
  WHERE a.judge_id=auth.uid();
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.reply_to_player_score_appeal(
  p_appeal_id uuid, p_reply text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'ابتدا وارد حساب داوری شوید.'; END IF;
  IF p_reply IS NULL OR length(btrim(p_reply)) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'پاسخ باید بین ۱ تا ۲۰۰۰ نویسه باشد.';
  END IF;
  UPDATE public.player_score_appeals
  SET judge_reply=btrim(p_reply), status='answered', answered_at=now()
  WHERE id=p_appeal_id AND judge_id=auth.uid() AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'اعتراض باز و متعلق به شما پیدا نشد.'; END IF;
  RETURN jsonb_build_object('success',true);
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_player_score_reviews() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_player_score_appeal(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_judge_score_appeals() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reply_to_player_score_appeal(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_player_score_reviews() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_player_score_appeal(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_judge_score_appeals() TO authenticated;
GRANT EXECUTE ON FUNCTION public.reply_to_player_score_appeal(uuid,text) TO authenticated;

COMMIT;
