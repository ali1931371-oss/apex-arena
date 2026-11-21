-- APEX ARENA: judge submission review workflow and manager directory.
-- Existing finalized submissions are preserved as approved/public results.
-- New judge submissions wait for manager approval before public publication.

BEGIN;

ALTER TABLE public.judge_game_submissions
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS review_note text;

ALTER TABLE public.judge_game_submissions
  DROP CONSTRAINT IF EXISTS judge_game_submissions_status_check;
ALTER TABLE public.judge_game_submissions
  DROP CONSTRAINT IF EXISTS judge_game_submissions_status_time_check;

-- Preserve already-published historical submissions.
UPDATE public.judge_game_submissions
SET status = 'approved'
WHERE status = 'submitted';

ALTER TABLE public.judge_game_submissions
  ADD CONSTRAINT judge_game_submissions_status_check
    CHECK (status IN ('draft','pending_review','approved','rejected')),
  ADD CONSTRAINT judge_game_submissions_status_time_check
    CHECK (
      (status = 'draft' AND submitted_at IS NULL)
      OR (status IN ('pending_review','approved','rejected') AND submitted_at IS NOT NULL)
    );

CREATE OR REPLACE FUNCTION public.save_judge_game_score(
  p_tournament_id uuid,
  p_stage_name text,
  p_game_number integer,
  p_player_id uuid,
  p_side text,
  p_role_name text,
  p_items jsonb,
  p_finalize boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $
DECLARE
  v_submission_id uuid;
  v_existing_status text;
  v_item_count integer;
  v_valid_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.tournament_judges tj
    WHERE tj.tournament_id = p_tournament_id
      AND tj.judge_id = auth.uid()
      AND tj.is_active = true
  ) THEN
    RAISE EXCEPTION 'شما داور فعال این تورنمنت نیستید.';
  END IF;

  IF p_stage_name IS NULL
     OR length(btrim(p_stage_name)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'نام مرحله باید بین ۱ تا ۱۰۰ نویسه باشد.';
  END IF;

  IF p_game_number IS NULL OR p_game_number NOT BETWEEN 1 AND 999 THEN
    RAISE EXCEPTION 'شماره بازی باید بین ۱ تا ۹۹۹ باشد.';
  END IF;

  IF p_side IS NULL OR p_side NOT IN ('شهروند', 'مافیا') THEN
    RAISE EXCEPTION 'ساید باید شهروند یا مافیا باشد.';
  END IF;

  IF p_role_name IS NULL
     OR length(btrim(p_role_name)) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'نام نقش باید بین ۱ تا ۱۰۰ نویسه باشد.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.tournament_memberships tm
    WHERE tm.tournament_id = p_tournament_id
      AND tm.player_id = p_player_id
      AND tm.status = 'active'
  ) THEN
    RAISE EXCEPTION 'بازیکن انتخاب‌شده عضو فعال این تورنمنت نیست.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.tournament_memberships tm
    JOIN public.tournament_judges tj
      ON tj.tournament_id = tm.tournament_id
     AND tj.judge_id = tm.user_id
     AND tj.is_active = true
     AND tj.is_player_restored = false
    WHERE tm.tournament_id = p_tournament_id
      AND tm.player_id = p_player_id
  ) THEN
    RAISE EXCEPTION 'داور فعال این تورنمنت نمی‌تواند به‌عنوان بازیکن امتیاز بگیرد.';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'فهرست امتیازها باید به‌صورت آرایه ارسال شود.';
  END IF;

  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'حداقل یک امتیاز برای ثبت لازم است.';
  END IF;

  SELECT count(*), count(DISTINCT x.criterion_id)
    INTO v_item_count, v_valid_count
  FROM jsonb_to_recordset(p_items) AS x(
    criterion_id uuid,
    raw_points numeric,
    notes text
  );

  IF v_item_count = 0 OR v_item_count <> v_valid_count THEN
    RAISE EXCEPTION 'فهرست معیارها خالی است یا یک معیار تکراری دارد.';
  END IF;

  SELECT count(*)
    INTO v_valid_count
  FROM jsonb_to_recordset(p_items) AS x(
    criterion_id uuid,
    raw_points numeric,
    notes text
  )
  JOIN public.tournament_criteria tc
    ON tc.id = x.criterion_id
   AND tc.tournament_id = p_tournament_id
   AND tc.is_active = true
  WHERE x.raw_points IS NOT NULL
    AND x.raw_points >= tc.min_points
    AND x.raw_points <= tc.max_points;

  IF v_valid_count <> v_item_count THEN
    RAISE EXCEPTION 'یک یا چند معیار متعلق به این تورنمنت نیست یا امتیاز آن خارج از محدوده مجاز است.';
  END IF;

  SELECT s.id, s.status
    INTO v_submission_id, v_existing_status
  FROM public.judge_game_submissions s
  WHERE s.tournament_id = p_tournament_id
    AND s.stage_key = lower(btrim(p_stage_name))
    AND s.game_number = p_game_number
    AND s.player_id = p_player_id
    AND s.judge_id = auth.uid()
  FOR UPDATE;

  IF v_existing_status IN ('pending_review', 'approved') THEN
    RAISE EXCEPTION 'این ارزیابی قبلاً نهایی شده و قابل ویرایش نیست.';
  END IF;

  IF v_submission_id IS NULL THEN
    INSERT INTO public.judge_game_submissions (
      tournament_id, stage_name, game_number, player_id,
      judge_id, side, role_name, status
    )
    VALUES (
      p_tournament_id, btrim(p_stage_name), p_game_number, p_player_id,
      auth.uid(), p_side, btrim(p_role_name), 'draft'
    )
    ON CONFLICT (
      tournament_id, stage_key, game_number, player_id, judge_id
    ) DO NOTHING
    RETURNING id INTO v_submission_id;

    IF v_submission_id IS NULL THEN
      SELECT s.id, s.status
        INTO v_submission_id, v_existing_status
      FROM public.judge_game_submissions s
      WHERE s.tournament_id = p_tournament_id
        AND s.stage_key = lower(btrim(p_stage_name))
        AND s.game_number = p_game_number
        AND s.player_id = p_player_id
        AND s.judge_id = auth.uid()
      FOR UPDATE;

      IF v_existing_status IN ('pending_review', 'approved') THEN
        RAISE EXCEPTION 'این ارزیابی قبلاً نهایی شده و قابل ویرایش نیست.';
      END IF;
    END IF;
  ELSE
    UPDATE public.judge_game_submissions
    SET stage_name = btrim(p_stage_name),
        side = p_side,
        role_name = btrim(p_role_name),
        updated_at = now()
    WHERE id = v_submission_id;
  END IF;

  DELETE FROM public.judge_game_score_items
  WHERE submission_id = v_submission_id;

  INSERT INTO public.judge_game_score_items (
    submission_id, criterion_id, raw_points, notes
  )
  SELECT
    v_submission_id, x.criterion_id, x.raw_points, x.notes
  FROM jsonb_to_recordset(p_items) AS x(
    criterion_id uuid,
    raw_points numeric,
    notes text
  );

  UPDATE public.judge_game_submissions
  SET status = CASE WHEN p_finalize THEN 'pending_review' ELSE 'draft' END,
      submitted_at = CASE WHEN p_finalize THEN now() ELSE NULL END,
      reviewed_at = NULL,
      reviewed_by = NULL,
      review_note = NULL,
      updated_at = now()
  WHERE id = v_submission_id;

  RETURN jsonb_build_object(
    'success', true,
    'submission_id', v_submission_id,
    'status', CASE WHEN p_finalize THEN 'pending_review' ELSE 'draft' END
  );
END;
$;

CREATE OR REPLACE FUNCTION public.get_judge_tournament_data(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.tournament_judges tj
    WHERE tj.tournament_id = p_tournament_id
      AND tj.judge_id = auth.uid()
      AND tj.is_active = true
  ) THEN
    RAISE EXCEPTION 'شما داور فعال این تورنمنت نیستید.';
  END IF;

  SELECT jsonb_build_object(
    'tournament', jsonb_build_object(
      'id', t.id,
      'name', t.name,
      'status', t.status
    ),
    'players', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'player_id', pl.id,
          'display_name', pl.display_name,
          'player_code', pl.player_code
        )
        ORDER BY pl.display_name, pl.player_code
      )
      FROM public.tournament_memberships tm
      JOIN public.players pl ON pl.id = tm.player_id
      WHERE tm.tournament_id = t.id
        AND tm.status = 'active'
        AND NOT EXISTS (
          SELECT 1
          FROM public.tournament_judges tj2
          WHERE tj2.tournament_id = t.id
            AND tj2.judge_id = tm.user_id
            AND tj2.is_active = true
            AND tj2.is_player_restored = false
        )
    ), '[]'::jsonb),
    'criteria', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', tc.id,
          'criterion_name', tc.criterion_name,
          'description', tc.description,
          'min_points', tc.min_points,
          'max_points', tc.max_points,
          'weight', tc.weight,
          'score_type', tc.score_type,
          'calculation_type', tc.calculation_type,
          'aggregation_method', tc.aggregation_method,
          'display_order', tc.display_order,
          'criterion_group', tc.criterion_group
        )
        ORDER BY tc.display_order
      )
      FROM public.tournament_criteria tc
      WHERE tc.tournament_id = t.id
        AND tc.is_active = true
    ), '[]'::jsonb),
    'submissions', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', s.id,
          'stage_name', s.stage_name,
          'game_number', s.game_number,
          'player_id', s.player_id,
          'side', s.side,
          'role_name', s.role_name,
          'status', s.status,
          'submitted_at', s.submitted_at,
          'reviewed_at', s.reviewed_at,
          'review_note', s.review_note,
          'items', COALESCE((
            SELECT jsonb_agg(
              jsonb_build_object(
                'criterion_id', si.criterion_id,
                'raw_points', si.raw_points,
                'notes', si.notes
              )
            )
            FROM public.judge_game_score_items si
            WHERE si.submission_id = s.id
          ), '[]'::jsonb)
        )
        ORDER BY s.created_at DESC
      )
      FROM public.judge_game_submissions s
      WHERE s.tournament_id = t.id
        AND s.judge_id = auth.uid()
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.tournaments t
  WHERE t.id = p_tournament_id;

  RETURN v_result;
END;
$;

CREATE OR REPLACE FUNCTION public.get_my_judge_dashboard()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_name text;
  v_tournaments jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'ابتدا وارد حساب داوری شوید.';
  END IF;

  SELECT p.display_name INTO v_name
  FROM public.profiles p
  WHERE p.id = auth.uid();

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'tournament_id', t.id,
      'tournament_name', t.name,
      'tournament_status', t.status
    ) ORDER BY t.created_at DESC
  ), '[]'::jsonb)
  INTO v_tournaments
  FROM public.tournament_judges tj
  JOIN public.tournaments t ON t.id = tj.tournament_id
  WHERE tj.judge_id = auth.uid()
    AND tj.is_active = true;

  RETURN jsonb_build_object(
    'judge_name', COALESCE(v_name, 'داور'),
    'tournaments', v_tournaments
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_manager_judge_directory()
RETURNS TABLE (
  tournament_id uuid,
  tournament_name text,
  judge_id uuid,
  judge_name text,
  is_active boolean,
  appointed_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'دسترسی مدیر یا مسئول مسابقه لازم است.';
  END IF;

  RETURN QUERY
  SELECT tj.tournament_id, t.name, tj.judge_id,
         p.display_name, tj.is_active, tj.created_at
  FROM public.tournament_judges tj
  JOIN public.tournaments t ON t.id = tj.tournament_id
  JOIN public.profiles p ON p.id = tj.judge_id
  ORDER BY t.name, tj.is_active DESC, p.display_name;
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

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', s.id,
      'tournament_id', s.tournament_id,
      'tournament_name', t.name,
      'stage_name', s.stage_name,
      'game_number', s.game_number,
      'player_id', s.player_id,
      'player_name', pl.display_name,
      'judge_id', s.judge_id,
      'judge_name', COALESCE(pr.display_name, pr.username, 'داور'),
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
    ) ORDER BY s.submitted_at DESC NULLS LAST, s.created_at DESC
  ), '[]'::jsonb)
  INTO v_result
  FROM public.judge_game_submissions s
  JOIN public.tournaments t ON t.id = s.tournament_id
  JOIN public.players pl ON pl.id = s.player_id
  JOIN public.profiles pr ON pr.id = s.judge_id
  WHERE s.tournament_id = p_tournament_id
    AND s.status IN ('pending_review','approved','rejected');

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.review_judge_game_submission(
  p_submission_id uuid,
  p_decision text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مسابقه می‌تواند ارزیابی را بررسی کند.';
  END IF;

  IF p_decision IS NULL OR p_decision NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'تصمیم باید تأیید یا رد باشد.';
  END IF;

  IF p_decision = 'rejected' AND v_note IS NULL THEN
    RAISE EXCEPTION 'برای رد ارزیابی، درج توضیح الزامی است.';
  END IF;

  SELECT s.status INTO v_status
  FROM public.judge_game_submissions s
  WHERE s.id = p_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ارزیابی موردنظر پیدا نشد.';
  END IF;
  IF v_status <> 'pending_review' THEN
    RAISE EXCEPTION 'فقط ارزیابی‌های در انتظار بررسی قابل تصمیم‌گیری هستند.';
  END IF;

  UPDATE public.judge_game_submissions
  SET status = p_decision,
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = v_note,
      updated_at = now()
  WHERE id = p_submission_id;

  RETURN jsonb_build_object('success', true, 'status', p_decision);
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

REVOKE ALL ON FUNCTION public.get_my_judge_dashboard() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_manager_judge_directory() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_manager_judge_game_submissions(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.review_judge_game_submission(uuid, text, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_my_judge_dashboard() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manager_judge_directory() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manager_judge_game_submissions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_judge_game_submission(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_judge_game_results(uuid) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
