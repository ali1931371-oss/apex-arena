-- APEX ARENA: allow the original judge to correct an appealed score.
-- Only the appealed player's result is reopened; manager approval is still required.
BEGIN;

CREATE OR REPLACE FUNCTION public.correct_player_score_appeal(
  p_appeal_id uuid,
  p_new_points numeric,
  p_judge_reply text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_appeal public.player_score_appeals%ROWTYPE;
  v_submission public.judge_game_submissions%ROWTYPE;
  v_criterion public.tournament_criteria%ROWTYPE;
  v_snapshot jsonb;
  v_audit_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'ابتدا وارد حساب داوری شوید.';
  END IF;
  IF p_judge_reply IS NULL OR length(btrim(p_judge_reply)) NOT BETWEEN 5 AND 900 THEN
    RAISE EXCEPTION 'توضیح اصلاح باید بین ۵ تا ۹۰۰ نویسه باشد.';
  END IF;

  SELECT * INTO v_appeal
  FROM public.player_score_appeals
  WHERE id = p_appeal_id AND judge_id = auth.uid()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'اعتراض متعلق به شما پیدا نشد.';
  END IF;

  SELECT * INTO v_submission
  FROM public.judge_game_submissions
  WHERE id = v_appeal.submission_id
    AND judge_id = auth.uid()
  FOR UPDATE;
  IF NOT FOUND OR v_submission.status <> 'approved' THEN
    RAISE EXCEPTION 'فقط ارزیابی تأییدشده خودتان از مسیر اعتراض قابل اصلاح است.';
  END IF;

  PERFORM 1 FROM public.tournaments
  WHERE id = v_submission.tournament_id
  FOR UPDATE;

  IF NOT EXISTS (
    SELECT 1 FROM public.judge_game_player_approvals a
    WHERE a.tournament_id = v_submission.tournament_id
      AND a.stage_key = v_submission.stage_key
      AND a.game_number = v_submission.game_number
      AND a.player_id = v_submission.player_id
  ) THEN
    RAISE EXCEPTION 'نتیجه این بازیکن در وضعیت انتشار نیست یا قبلاً برای اصلاح باز شده است.';
  END IF;

  SELECT tc.* INTO v_criterion
  FROM public.judge_game_score_items si
  JOIN public.tournament_criteria tc ON tc.id = si.criterion_id
  WHERE si.id = v_appeal.score_item_id
    AND si.submission_id = v_submission.id
    AND tc.tournament_id = v_submission.tournament_id
    AND tc.is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'معیار امتیاز مورد اعتراض فعال یا معتبر نیست.';
  END IF;
  IF p_new_points IS NULL
     OR p_new_points < v_criterion.min_points
     OR p_new_points > v_criterion.max_points THEN
    RAISE EXCEPTION 'نمره جدید باید بین % و % باشد.',
      v_criterion.min_points, v_criterion.max_points;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.tournament_judges tj
    WHERE tj.tournament_id = v_submission.tournament_id
      AND tj.judge_id = auth.uid()
      AND tj.is_active = true
  ) THEN
    RAISE EXCEPTION 'شما دیگر داور فعال این تورنمنت نیستید.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'submission_id', s.id,
    'judge_id', s.judge_id,
    'replacement_for_judge_id', s.replacement_for_judge_id,
    'status', s.status,
    'side', s.side,
    'role_name', s.role_name,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'criterion_id', si.criterion_id,
        'raw_points', si.raw_points,
        'notes', si.notes
      ) ORDER BY si.criterion_id)
      FROM public.judge_game_score_items si
      WHERE si.submission_id = s.id
    ), '[]'::jsonb)
  ) ORDER BY s.judge_id), '[]'::jsonb)
  INTO v_snapshot
  FROM public.judge_game_submissions s
  WHERE s.tournament_id = v_submission.tournament_id
    AND s.stage_key = v_submission.stage_key
    AND s.game_number = v_submission.game_number
    AND s.player_id = v_submission.player_id
    AND s.status = 'approved';

  INSERT INTO public.judge_game_correction_audit (
    tournament_id, stage_name, game_number,
    reopened_by, reason, previous_scores
  ) VALUES (
    v_submission.tournament_id, v_submission.stage_name,
    v_submission.game_number, auth.uid(),
    'اصلاح نمره در پاسخ به اعتراض بازیکن: ' || btrim(p_judge_reply),
    v_snapshot
  ) RETURNING id INTO v_audit_id;

  UPDATE public.judge_game_score_items
  SET raw_points = p_new_points
  WHERE id = v_appeal.score_item_id
    AND submission_id = v_submission.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ردیف نمره مورد اعتراض پیدا نشد.';
  END IF;

  DELETE FROM public.judge_game_player_approvals
  WHERE tournament_id = v_submission.tournament_id
    AND stage_key = v_submission.stage_key
    AND game_number = v_submission.game_number
    AND player_id = v_submission.player_id;

  -- Keep every judge's score, but return this player's complete score set
  -- to manager review. No other player's publication is touched.
  UPDATE public.judge_game_submissions
  SET status = 'pending_review',
      submitted_at = now(),
      reviewed_at = NULL,
      reviewed_by = NULL,
      review_note = NULL,
      updated_at = now()
  WHERE tournament_id = v_submission.tournament_id
    AND stage_key = v_submission.stage_key
    AND game_number = v_submission.game_number
    AND player_id = v_submission.player_id
    AND status = 'approved';

  UPDATE public.player_score_appeals
  SET judge_reply = btrim(p_judge_reply),
      status = 'answered',
      answered_at = now()
  WHERE id = p_appeal_id;

  RETURN jsonb_build_object(
    'success', true,
    'correction_audit_id', v_audit_id,
    'new_points', p_new_points,
    'status', 'pending_review',
    'message', 'نمره اصلاح شد و نتیجه همین بازیکن برای تأیید مجدد مدیر ارسال شد.'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.correct_player_score_appeal(uuid,numeric,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_player_score_appeal(uuid,numeric,text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
