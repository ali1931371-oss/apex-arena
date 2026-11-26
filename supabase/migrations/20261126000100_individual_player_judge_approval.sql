-- APEX ARENA: independent player approval and automatic judge-score averaging.
-- Keeps legacy game approvals and correction audit history intact.
BEGIN;
CREATE TABLE IF NOT EXISTS public.judge_game_player_approvals (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
 stage_name text NOT NULL,
 stage_key text GENERATED ALWAYS AS (lower(btrim(stage_name))) STORED,
 game_number integer NOT NULL CHECK (game_number BETWEEN 1 AND 999),
 player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,
 approved_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
 approved_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(tournament_id,stage_key,game_number,player_id)
);
ALTER TABLE public.judge_game_player_approvals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.judge_game_player_approvals FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.approve_judge_player_result(
  p_tournament_id uuid, p_stage_name text, p_game_number integer, p_player_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_required integer; v_active integer; v_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مسابقه می‌تواند ارزیابی‌های بازیکن را تأیید کند.';
  END IF;
  IF p_stage_name IS NULL OR length(btrim(p_stage_name)) NOT BETWEEN 1 AND 100
     OR p_game_number IS NULL OR p_game_number NOT BETWEEN 1 AND 999 OR p_player_id IS NULL THEN
    RAISE EXCEPTION 'مرحله، شماره بازی یا بازیکن معتبر نیست.';
  END IF;
  PERFORM 1 FROM public.tournaments WHERE id=p_tournament_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'تورنمنت پیدا نشد.'; END IF;
  IF EXISTS (SELECT 1 FROM public.judge_game_player_approvals
    WHERE tournament_id=p_tournament_id AND stage_key=lower(btrim(p_stage_name))
      AND game_number=p_game_number AND player_id=p_player_id) THEN
    RAISE EXCEPTION 'نتیجه این بازیکن قبلاً تأیید و منتشر شده است.';
  END IF;
  SELECT required_judge_count INTO v_required FROM public.tournament_judging_settings
    WHERE tournament_id=p_tournament_id;
  SELECT count(*)::integer INTO v_active FROM public.tournament_judges
    WHERE tournament_id=p_tournament_id AND is_active=true;
  IF v_required IS NULL OR v_active<>v_required THEN
    RAISE EXCEPTION 'تعداد داوران فعال با تعداد تعیین‌شده تورنمنت مطابقت ندارد.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tournament_memberships
    WHERE tournament_id=p_tournament_id AND player_id=p_player_id AND status='active') THEN
    RAISE EXCEPTION 'بازیکن عضو فعال این تورنمنت نیست.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.tournament_judges tj
    WHERE tj.tournament_id=p_tournament_id AND tj.is_active=true
      AND NOT EXISTS (
        SELECT 1 FROM public.judge_game_submissions s
        WHERE s.tournament_id=p_tournament_id AND s.stage_key=lower(btrim(p_stage_name))
          AND s.game_number=p_game_number AND s.player_id=p_player_id
          AND COALESCE(s.replacement_for_judge_id,s.judge_id)=tj.judge_id
          AND s.status='pending_review'
      )
  ) THEN RAISE EXCEPTION 'هنوز ارزیابی نهایی همه داوران برای این بازیکن ثبت نشده است.'; END IF;
  SELECT count(*)::integer INTO v_count FROM public.judge_game_submissions
    WHERE tournament_id=p_tournament_id AND stage_key=lower(btrim(p_stage_name))
      AND game_number=p_game_number AND player_id=p_player_id AND status='pending_review';
  IF v_count<>v_required THEN
    RAISE EXCEPTION 'تعداد ارزیابی‌های نهایی این بازیکن (%) با تعداد داوران لازم (%) برابر نیست.',v_count,v_required;
  END IF;
  INSERT INTO public.judge_game_player_approvals
    (tournament_id,stage_name,game_number,player_id,approved_by)
  VALUES (p_tournament_id,btrim(p_stage_name),p_game_number,p_player_id,auth.uid());
  UPDATE public.judge_game_submissions
  SET status='approved',reviewed_at=now(),reviewed_by=auth.uid(),
      review_note='تأیید ارزیابی‌های همین بازیکن و انتشار خودکار میانگین',updated_at=now()
  WHERE tournament_id=p_tournament_id AND stage_key=lower(btrim(p_stage_name))
    AND game_number=p_game_number AND player_id=p_player_id AND status='pending_review';
  RETURN jsonb_build_object('success',true,'player_id',p_player_id,
    'approved_count',v_count,'required_judge_count',v_required,'publication_mode','average');
END;
$$;
CREATE OR REPLACE FUNCTION public.save_judge_game_score(
  p_tournament_id uuid,
  p_stage_name text,
  p_game_number integer,
  p_player_id uuid,
  p_side text,
  p_role_name text,
  p_items jsonb,
  p_finalize boolean DEFAULT false,
  p_replacement_for_judge_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_submission_id uuid;
  v_existing_status text;
  v_slot_id uuid;
  v_item_count integer;
  v_valid_count integer;
  v_required integer;
  v_active integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'ابتدا وارد حساب کاربری شوید.'; END IF;

  IF p_replacement_for_judge_id IS NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.tournament_judges tj
      WHERE tj.tournament_id = p_tournament_id
        AND tj.judge_id = auth.uid() AND tj.is_active = true
    ) THEN
      RAISE EXCEPTION 'شما داور فعال این تورنمنت نیستید.';
    END IF;
    v_slot_id := auth.uid();
  ELSE
    IF NOT public.is_apex_manager() THEN
      RAISE EXCEPTION 'ثبت داوری جایگزین فقط برای مدیر یا مسئول مسابقه مجاز است.';
    END IF;
    IF p_replacement_for_judge_id = auth.uid() THEN
      RAISE EXCEPTION 'مدیر نمی‌تواند جایگزین امتیاز خودش شود.';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.tournament_judges tj
      WHERE tj.tournament_id = p_tournament_id
        AND tj.judge_id = p_replacement_for_judge_id
        AND tj.is_active = true
    ) THEN
      RAISE EXCEPTION 'داور موردنظر، داور فعال این تورنمنت نیست.';
    END IF;
    v_slot_id := p_replacement_for_judge_id;
    IF EXISTS (
      SELECT 1 FROM public.judge_game_submissions s
      WHERE s.tournament_id = p_tournament_id
        AND s.stage_key = lower(btrim(p_stage_name))
        AND s.game_number = p_game_number
        AND s.player_id = p_player_id
        AND s.judge_id = p_replacement_for_judge_id
        AND s.replacement_for_judge_id IS NULL
        AND s.status IN ('pending_review','approved')
    ) THEN
      RAISE EXCEPTION 'این داور قبلاً امتیاز نهایی خود را ارسال کرده است؛ جایگزینی مجاز نیست.';
    END IF;
  END IF;

  SELECT required_judge_count INTO v_required
  FROM public.tournament_judging_settings
  WHERE tournament_id = p_tournament_id;
  SELECT count(*)::integer INTO v_active
  FROM public.tournament_judges
  WHERE tournament_id = p_tournament_id AND is_active = true;
  IF v_required IS NULL OR v_active <> v_required THEN
    RAISE EXCEPTION 'ابتدا باید دقیقاً تعداد داوران تعیین‌شده برای تورنمنت منصوب شوند.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.judge_game_player_approvals a
    WHERE a.tournament_id = p_tournament_id
      AND a.stage_key = lower(btrim(p_stage_name))
      AND a.game_number = p_game_number
      AND a.player_id = p_player_id
  ) THEN
    RAISE EXCEPTION 'نتیجه این بازیکن تأیید و منتشر شده و ارزیابی او قفل است.';
  END IF;

  IF p_stage_name IS NULL OR length(btrim(p_stage_name)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'نام مرحله باید بین ۱ تا ۱۰۰ نویسه باشد.';
  END IF;
  IF p_game_number IS NULL OR p_game_number NOT BETWEEN 1 AND 999 THEN
    RAISE EXCEPTION 'شماره بازی باید بین ۱ تا ۹۹۹ باشد.';
  END IF;
  IF p_side IS NULL OR p_side NOT IN ('شهروند', 'مافیا') THEN
    RAISE EXCEPTION 'ساید باید شهروند یا مافیا باشد.';
  END IF;
  IF p_role_name IS NULL OR length(btrim(p_role_name)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'نام نقش باید بین ۱ تا ۱۰۰ نویسه باشد.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.tournament_memberships tm
    WHERE tm.tournament_id = p_tournament_id
      AND tm.player_id = p_player_id AND tm.status = 'active'
  ) THEN RAISE EXCEPTION 'بازیکن انتخاب‌شده عضو فعال این تورنمنت نیست.'; END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'فهرست معیارها باید آرایه غیرخالی باشد.';
  END IF;

  SELECT count(*), count(DISTINCT x.criterion_id)
  INTO v_item_count, v_valid_count
  FROM jsonb_to_recordset(p_items) AS x(criterion_id uuid, raw_points numeric, notes text);
  IF v_item_count = 0 OR v_item_count <> v_valid_count THEN
    RAISE EXCEPTION 'فهرست معیارها خالی است یا معیار تکراری دارد.';
  END IF;

  SELECT count(*) INTO v_valid_count
  FROM jsonb_to_recordset(p_items) AS x(criterion_id uuid, raw_points numeric, notes text)
  JOIN public.tournament_criteria tc
    ON tc.id = x.criterion_id AND tc.tournament_id = p_tournament_id AND tc.is_active = true
  WHERE x.raw_points IS NOT NULL
    AND x.raw_points >= tc.min_points AND x.raw_points <= tc.max_points;
  IF v_valid_count <> v_item_count THEN
    RAISE EXCEPTION 'یک یا چند معیار نامعتبر یا خارج از محدوده مجاز است.';
  END IF;

  IF p_replacement_for_judge_id IS NULL AND EXISTS (
    SELECT 1 FROM public.judge_game_submissions s
    WHERE s.tournament_id = p_tournament_id
      AND s.stage_key = lower(btrim(p_stage_name))
      AND s.game_number = p_game_number
      AND s.player_id = p_player_id
      AND s.replacement_for_judge_id = auth.uid()
      AND s.status IN ('pending_review','approved')
  ) THEN
    RAISE EXCEPTION 'مدیر برای ارزیابی همین بازیکن جایگزین شما شده است؛ برای این بازیکن دیگر امکان ثبت امتیاز ندارید.';
  END IF;

  SELECT s.id, s.status INTO v_submission_id, v_existing_status
  FROM public.judge_game_submissions s
  WHERE s.tournament_id = p_tournament_id
    AND s.stage_key = lower(btrim(p_stage_name))
    AND s.game_number = p_game_number
    AND s.player_id = p_player_id
    AND s.judge_id = auth.uid()
    AND s.replacement_for_judge_id IS NOT DISTINCT FROM p_replacement_for_judge_id
  FOR UPDATE;

  IF v_existing_status IN ('pending_review','approved') THEN
    RAISE EXCEPTION 'این ارزیابی قبلاً ارسال نهایی شده و قابل ویرایش نیست.';
  END IF;

  IF v_submission_id IS NULL THEN
    INSERT INTO public.judge_game_submissions (
      tournament_id, stage_name, game_number, player_id, judge_id,
      replacement_for_judge_id, side, role_name, status
    ) VALUES (
      p_tournament_id, btrim(p_stage_name), p_game_number, p_player_id,
      auth.uid(), p_replacement_for_judge_id, p_side, btrim(p_role_name),
      'draft'
    ) RETURNING id INTO v_submission_id;
  ELSE
    UPDATE public.judge_game_submissions
    SET stage_name = btrim(p_stage_name), side = p_side,
        role_name = btrim(p_role_name), updated_at = now()
    WHERE id = v_submission_id;
  END IF;

  DELETE FROM public.judge_game_score_items WHERE submission_id = v_submission_id;
  INSERT INTO public.judge_game_score_items (submission_id, criterion_id, raw_points, notes)
  SELECT v_submission_id, x.criterion_id, x.raw_points, x.notes
  FROM jsonb_to_recordset(p_items) AS x(criterion_id uuid, raw_points numeric, notes text);

  UPDATE public.judge_game_submissions
  SET status = CASE WHEN p_finalize THEN 'pending_review' ELSE 'draft' END,
      submitted_at = CASE WHEN p_finalize THEN now() ELSE NULL END,
      reviewed_at = NULL, reviewed_by = NULL, review_note = NULL,
      updated_at = now()
  WHERE id = v_submission_id;

  RETURN jsonb_build_object(
    'success', true, 'submission_id', v_submission_id,
    'status', CASE WHEN p_finalize THEN 'pending_review' ELSE 'draft' END,
    'replacement_for_judge_id', p_replacement_for_judge_id
  );
END;
$$;
CREATE OR REPLACE FUNCTION public.get_manager_judge_game_submissions(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'دسترسی مدیر یا مسئول مسابقه لازم است.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'tournament_id', s.tournament_id,
    'tournament_name', t.name,
    'stage_name', s.stage_name,
    'game_number', s.game_number,
    'player_id', s.player_id,
    'player_name', pl.display_name,
    'judge_id', s.judge_id,
    'judge_name', COALESCE(pr.display_name, pr.username, 'داور'),
    'replacement_for_judge_id', s.replacement_for_judge_id,
    'replacement_for_judge_name', COALESCE(slot.display_name, ''),
    'group_approved', EXISTS (
      SELECT 1 FROM public.judge_game_player_approvals pa
      WHERE pa.tournament_id = s.tournament_id
        AND pa.stage_key = s.stage_key
        AND pa.game_number = s.game_number
        AND pa.player_id = s.player_id
    ),
    'side', s.side,
    'role_name', s.role_name,
    'status', s.status,
    'submitted_at', s.submitted_at,
    'reviewed_at', s.reviewed_at,
    'review_note', s.review_note,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'criterion_name', tc.criterion_name,
        'criterion_group', tc.criterion_group,
        'raw_points', si.raw_points,
        'notes', si.notes
      ) ORDER BY tc.display_order)
      FROM public.judge_game_score_items si
      JOIN public.tournament_criteria tc ON tc.id = si.criterion_id
      WHERE si.submission_id = s.id
    ), '[]'::jsonb)
  ) ORDER BY s.stage_key, s.game_number, pl.display_name, pr.display_name), '[]'::jsonb)
  INTO v_result
  FROM public.judge_game_submissions s
  JOIN public.tournaments t ON t.id = s.tournament_id
  JOIN public.players pl ON pl.id = s.player_id
  JOIN public.profiles pr ON pr.id = s.judge_id
  LEFT JOIN public.profiles slot ON slot.id = s.replacement_for_judge_id
  WHERE s.tournament_id = p_tournament_id
    AND s.status IN ('pending_review','approved','rejected');
  RETURN v_result;
END;
$$;
CREATE OR REPLACE FUNCTION public.get_public_judge_game_results(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.tournaments t WHERE t.id = p_tournament_id
  ) THEN
    RAISE EXCEPTION 'تورنمنت پیدا نشد.';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'stage_name', g.stage_name,
      'game_number', g.game_number,
      'player_id', g.player_id,
      'display_name', g.display_name,
      'player_code', g.player_code,
      'side', meta.side,
      'role_name', meta.role_name,
      'judge_count', g.judge_count,
      'criteria', scores.criteria,
      'technical_total', scores.technical_total,
      'bonus_total', scores.bonus_total,
      'penalty_total', scores.penalty_total,
      'final_total', scores.technical_total
        + scores.bonus_total - scores.penalty_total
    )
    ORDER BY g.stage_key, g.game_number, g.display_name
  ), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      s.tournament_id,
      s.stage_key,
      min(s.stage_name) AS stage_name,
      s.game_number,
      s.player_id,
      pl.display_name,
      pl.player_code,
      count(*) AS judge_count
    FROM public.judge_game_submissions s
    JOIN public.players pl ON pl.id = s.player_id
    WHERE s.tournament_id = p_tournament_id
      AND s.status = 'approved'
    GROUP BY
      s.tournament_id, s.stage_key, s.game_number,
      s.player_id, pl.display_name, pl.player_code
  ) g
  CROSS JOIN LATERAL (
    SELECT s.side, s.role_name
    FROM public.judge_game_submissions s
    WHERE s.tournament_id = g.tournament_id
      AND s.stage_key = g.stage_key
      AND s.game_number = g.game_number
      AND s.player_id = g.player_id
      AND s.status = 'approved'
    ORDER BY s.submitted_at DESC, s.created_at DESC
    LIMIT 1
  ) meta
  CROSS JOIN LATERAL (
    SELECT
      COALESCE(jsonb_agg(
        jsonb_build_object(
          'criterion_id', c.criterion_id,
          'criterion_name', c.criterion_name,
          'criterion_group', c.criterion_group,
          'average_points', c.average_points
        )
        ORDER BY c.display_order
      ), '[]'::jsonb) AS criteria,
      COALESCE(sum(c.average_points) FILTER (
        WHERE c.criterion_group IN ('general', 'citizen', 'mafia')
      ), 0) AS technical_total,
      COALESCE(sum(c.average_points) FILTER (
        WHERE c.criterion_group = 'bonus'
      ), 0) AS bonus_total,
      COALESCE(sum(c.average_points) FILTER (
        WHERE c.criterion_group = 'penalty'
      ), 0) AS penalty_total
    FROM (
      SELECT
        tc.id AS criterion_id,
        tc.criterion_name,
        tc.criterion_group,
        tc.display_order,
        avg(si.raw_points)::numeric(10,2) AS average_points
      FROM public.judge_game_submissions s
      JOIN public.judge_game_score_items si ON si.submission_id = s.id
      JOIN public.tournament_criteria tc ON tc.id = si.criterion_id
      WHERE s.tournament_id = g.tournament_id
        AND s.stage_key = g.stage_key
        AND s.game_number = g.game_number
        AND s.player_id = g.player_id
        AND s.status = 'approved'
      GROUP BY tc.id, tc.criterion_name, tc.criterion_group, tc.display_order
    ) c
  ) scores;

  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.approve_judge_player_result(uuid,text,integer,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_judge_player_result(uuid,text,integer,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_manager_judge_game_submissions(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_manager_judge_game_submissions(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_judge_game_results(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_judge_game_results(uuid) TO anon,authenticated;
REVOKE ALL ON FUNCTION public.save_judge_game_score(uuid,text,integer,uuid,text,text,jsonb,boolean,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_judge_game_score(uuid,text,integer,uuid,text,text,jsonb,boolean,uuid) TO authenticated;
-- Disable the legacy whole-game approval RPC so it cannot bypass per-player review.
REVOKE ALL ON FUNCTION public.approve_judge_game_results(uuid,text,integer) FROM PUBLIC,anon,authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
