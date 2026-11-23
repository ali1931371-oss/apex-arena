-- APEX ARENA: fixed tournament judge count, manager replacement, and game-level approval.
-- New workflow: all assigned judge slots must be filled for every active player in a game.
-- Manager replacements occupy the absent judge's slot; only game-level approval publishes averages.

BEGIN;

CREATE TABLE IF NOT EXISTS public.tournament_judging_settings (
  tournament_id uuid PRIMARY KEY REFERENCES public.tournaments(id) ON DELETE CASCADE,
  required_judge_count integer NOT NULL DEFAULT 1
    CHECK (required_judge_count BETWEEN 1 AND 3),
  publication_mode text NOT NULL DEFAULT 'average'
    CHECK (publication_mode = 'average'),
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.tournament_judging_settings (tournament_id, required_judge_count)
SELECT t.id, greatest(1, least(3, count(tj.judge_id)::integer))
FROM public.tournaments t
LEFT JOIN public.tournament_judges tj
  ON tj.tournament_id = t.id AND tj.is_active = true
GROUP BY t.id
ON CONFLICT (tournament_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.seed_tournament_judging_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.tournament_judging_settings (tournament_id, required_judge_count)
  VALUES (NEW.id, 1)
  ON CONFLICT (tournament_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS seed_tournament_judging_settings_after_insert ON public.tournaments;
CREATE TRIGGER seed_tournament_judging_settings_after_insert
AFTER INSERT ON public.tournaments
FOR EACH ROW EXECUTE FUNCTION public.seed_tournament_judging_settings();

ALTER TABLE public.judge_game_submissions
  ADD COLUMN IF NOT EXISTS replacement_for_judge_id uuid
    REFERENCES public.profiles(id) ON DELETE RESTRICT;

ALTER TABLE public.judge_game_submissions
  DROP CONSTRAINT IF EXISTS judge_game_submissions_unique_judge_entry;

CREATE UNIQUE INDEX IF NOT EXISTS judge_game_submissions_normal_slot_unique
  ON public.judge_game_submissions
    (tournament_id, stage_key, game_number, player_id, judge_id)
  WHERE replacement_for_judge_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS judge_game_submissions_replacement_slot_unique
  ON public.judge_game_submissions
    (tournament_id, stage_key, game_number, player_id, replacement_for_judge_id)
  WHERE replacement_for_judge_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS judge_game_submissions_replacement_lookup
  ON public.judge_game_submissions
    (tournament_id, stage_key, game_number, replacement_for_judge_id);

CREATE TABLE IF NOT EXISTS public.judge_game_game_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES public.tournaments(id) ON DELETE CASCADE,
  stage_name text NOT NULL,
  stage_key text GENERATED ALWAYS AS (lower(btrim(stage_name))) STORED,
  game_number integer NOT NULL CHECK (game_number BETWEEN 1 AND 999),
  approved_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_at timestamptz NOT NULL DEFAULT now(),
  correction_note text,
  UNIQUE (tournament_id, stage_key, game_number)
);

ALTER TABLE public.judge_game_game_approvals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.judge_game_game_approvals FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_tournament_judge_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer;
  v_active integer;
BEGIN
  IF NEW.is_active = true
     AND (TG_OP = 'INSERT' OR OLD.is_active = false) THEN
    SELECT required_judge_count INTO v_limit
    FROM public.tournament_judging_settings
    WHERE tournament_id = NEW.tournament_id
    FOR UPDATE;

    IF v_limit IS NULL THEN
      v_limit := 1;
    END IF;

    SELECT count(*)::integer INTO v_active
    FROM public.tournament_judges
    WHERE tournament_id = NEW.tournament_id
      AND is_active = true;

    IF v_active >= v_limit THEN
      RAISE EXCEPTION 'تعداد داوران فعال به سقف تعیین‌شده این تورنمنت رسیده است. ابتدا ظرفیت داوری را در تنظیمات تغییر بدهید.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_tournament_judge_limit_before_write ON public.tournament_judges;
CREATE TRIGGER enforce_tournament_judge_limit_before_write
BEFORE INSERT OR UPDATE OF is_active, tournament_id
ON public.tournament_judges
FOR EACH ROW EXECUTE FUNCTION public.enforce_tournament_judge_limit();

CREATE OR REPLACE FUNCTION public.get_tournament_judging_config(p_tournament_id uuid)
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

  SELECT jsonb_build_object(
    'required_judge_count', s.required_judge_count,
    'publication_mode', s.publication_mode,
    'active_judge_count', (
      SELECT count(*) FROM public.tournament_judges tj
      WHERE tj.tournament_id = p_tournament_id AND tj.is_active = true
    ),
    'judges', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', p.id,
        'display_name', p.display_name,
        'is_active', tj.is_active
      ) ORDER BY p.display_name)
      FROM public.tournament_judges tj
      JOIN public.profiles p ON p.id = tj.judge_id
      WHERE tj.tournament_id = p_tournament_id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.tournament_judging_settings s
  WHERE s.tournament_id = p_tournament_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'تنظیمات داوری تورنمنت پیدا نشد.';
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_tournament_judge_count(
  p_tournament_id uuid,
  p_required_judge_count integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_active integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مسابقه می‌تواند ساختار داوری را تنظیم کند.';
  END IF;
  IF p_required_judge_count IS NULL OR p_required_judge_count NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'تعداد داوران باید ۱، ۲ یا ۳ باشد.';
  END IF;

  PERFORM 1 FROM public.tournaments
  WHERE id = p_tournament_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'تورنمنت پیدا نشد.'; END IF;

  SELECT count(*)::integer INTO v_active
  FROM public.tournament_judges
  WHERE tournament_id = p_tournament_id AND is_active = true;

  IF v_active > p_required_judge_count THEN
    RAISE EXCEPTION 'در حال حاضر % داور فعال دارید. ابتدا داوران اضافی را لغو انتصاب کنید.', v_active;
  END IF;

  INSERT INTO public.tournament_judging_settings
    (tournament_id, required_judge_count, publication_mode, updated_by, updated_at)
  VALUES (p_tournament_id, p_required_judge_count, 'average', auth.uid(), now())
  ON CONFLICT (tournament_id) DO UPDATE
  SET required_judge_count = EXCLUDED.required_judge_count,
      publication_mode = 'average',
      updated_by = auth.uid(),
      updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'required_judge_count', p_required_judge_count,
    'active_judge_count', v_active,
    'publication_mode', 'average'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_manager_judge_tournament_data(p_tournament_id uuid)
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

  SELECT jsonb_build_object(
    'tournament', jsonb_build_object('id', t.id, 'name', t.name, 'status', t.status),
    'required_judge_count', cfg.required_judge_count,
    'judges', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', p.id, 'display_name', p.display_name
      ) ORDER BY p.display_name)
      FROM public.tournament_judges tj
      JOIN public.profiles p ON p.id = tj.judge_id
      WHERE tj.tournament_id = t.id AND tj.is_active = true
    ), '[]'::jsonb),
    'players', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'player_id', pl.id,
        'display_name', pl.display_name,
        'player_code', pl.player_code
      ) ORDER BY pl.display_name, pl.player_code)
      FROM public.tournament_memberships tm
      JOIN public.players pl ON pl.id = tm.player_id
      WHERE tm.tournament_id = t.id AND tm.status = 'active'
        AND NOT EXISTS (
          SELECT 1 FROM public.tournament_judges tj
          WHERE tj.tournament_id = t.id AND tj.judge_id = tm.user_id
            AND tj.is_active = true AND tj.is_player_restored = false
        )
    ), '[]'::jsonb),
    'criteria', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', tc.id, 'criterion_name', tc.criterion_name,
        'description', tc.description, 'min_points', tc.min_points,
        'max_points', tc.max_points, 'display_order', tc.display_order,
        'criterion_group', tc.criterion_group
      ) ORDER BY tc.display_order)
      FROM public.tournament_criteria tc
      WHERE tc.tournament_id = t.id AND tc.is_active = true
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.tournaments t
  JOIN public.tournament_judging_settings cfg ON cfg.tournament_id = t.id
  WHERE t.id = p_tournament_id;

  IF v_result IS NULL THEN RAISE EXCEPTION 'تورنمنت پیدا نشد.'; END IF;
  RETURN v_result;
END;
$$;

DROP FUNCTION IF EXISTS public.save_judge_game_score(uuid, text, integer, uuid, text, text, jsonb, boolean);

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
    SELECT 1 FROM public.judge_game_game_approvals a
    WHERE a.tournament_id = p_tournament_id
      AND a.stage_key = lower(btrim(p_stage_name))
      AND a.game_number = p_game_number
  ) THEN
    RAISE EXCEPTION 'نتیجه این بازی تأیید و منتشر شده و امتیازدهی آن قفل است.';
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
      AND s.game_number = p_game_number AND s.player_id = p_player_id
      AND s.replacement_for_judge_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'مدیر برای این بازی جایگزین شما شده است؛ دیگر امکان ثبت امتیاز ندارید.';
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
  IF p_decision IS DISTINCT FROM 'rejected' THEN
    RAISE EXCEPTION 'تأیید باید برای کل بازی انجام شود؛ از گزینه تأیید نهایی بازی استفاده کنید.';
  END IF;
  IF v_note IS NULL THEN RAISE EXCEPTION 'برای رد ارزیابی، درج توضیح الزامی است.'; END IF;

  SELECT s.status INTO v_status
  FROM public.judge_game_submissions s
  WHERE s.id = p_submission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ارزیابی موردنظر پیدا نشد.'; END IF;
  IF v_status <> 'pending_review' THEN
    RAISE EXCEPTION 'فقط ارزیابی‌های در انتظار بررسی قابل رد هستند.';
  END IF;

  UPDATE public.judge_game_submissions
  SET status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(),
      review_note = v_note, updated_at = now()
  WHERE id = p_submission_id;
  RETURN jsonb_build_object('success', true, 'status', 'rejected');
END;
$$;

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
  v_player_count integer;
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
  ) THEN RAISE EXCEPTION 'این بازی قبلاً تأیید و منتشر شده است.'; END IF;

  SELECT required_judge_count INTO v_required
  FROM public.tournament_judging_settings WHERE tournament_id = p_tournament_id;
  SELECT count(*)::integer INTO v_active
  FROM public.tournament_judges WHERE tournament_id = p_tournament_id AND is_active = true;
  IF v_required IS NULL OR v_active <> v_required THEN
    RAISE EXCEPTION 'تعداد داوران فعال با تعداد تعیین‌شده تورنمنت مطابقت ندارد.';
  END IF;

  SELECT count(*)::integer INTO v_player_count
  FROM public.tournament_memberships tm
  WHERE tm.tournament_id = p_tournament_id AND tm.status = 'active'
    AND NOT EXISTS (
      SELECT 1 FROM public.tournament_judges tj
      WHERE tj.tournament_id = p_tournament_id
        AND tj.judge_id = tm.user_id AND tj.is_active = true
        AND tj.is_player_restored = false
    );
  IF v_player_count = 0 THEN RAISE EXCEPTION 'بازیکن فعالی برای این تورنمنت وجود ندارد.'; END IF;
  v_expected := v_player_count * v_required;

  IF EXISTS (
    SELECT 1
    FROM public.tournament_memberships tm
    JOIN public.players pl ON pl.id = tm.player_id
    CROSS JOIN public.tournament_judges tj
    WHERE tm.tournament_id = p_tournament_id AND tm.status = 'active'
      AND tj.tournament_id = p_tournament_id AND tj.is_active = true
      AND NOT EXISTS (
        SELECT 1 FROM public.tournament_judges self_judge
        WHERE self_judge.tournament_id = p_tournament_id
          AND self_judge.judge_id = tm.user_id
          AND self_judge.is_active = true AND self_judge.is_player_restored = false
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.judge_game_submissions s
        WHERE s.tournament_id = p_tournament_id
          AND s.stage_key = lower(btrim(p_stage_name))
          AND s.game_number = p_game_number
          AND s.player_id = pl.id
          AND COALESCE(s.replacement_for_judge_id, s.judge_id) = tj.judge_id
          AND s.status = 'pending_review'
      )
  ) THEN
    RAISE EXCEPTION 'همه داوران برای تمام بازیکنان این بازی امتیاز نهایی ارسال نکرده‌اند. ابتدا جای خالی داوران را تکمیل کنید.';
  END IF;

  SELECT count(*)::integer INTO v_updated
  FROM public.judge_game_submissions s
  WHERE s.tournament_id = p_tournament_id
    AND s.stage_key = lower(btrim(p_stage_name))
    AND s.game_number = p_game_number
    AND s.status = 'pending_review';

  IF v_updated <> v_expected THEN
    RAISE EXCEPTION 'تعداد ارزیابی‌های نهایی (%s) با تعداد موردنیاز (%s) برابر نیست.', v_updated, v_expected;
  END IF;

  INSERT INTO public.judge_game_game_approvals
    (tournament_id, stage_name, game_number, approved_by)
  VALUES (p_tournament_id, btrim(p_stage_name), p_game_number, auth.uid());

  UPDATE public.judge_game_submissions
  SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid(),
      review_note = 'تأیید گروهی بازی و انتشار میانگین', updated_at = now()
  WHERE tournament_id = p_tournament_id
    AND stage_key = lower(btrim(p_stage_name))
    AND game_number = p_game_number
    AND status = 'pending_review';

  RETURN jsonb_build_object(
    'success', true,
    'approved_count', v_updated,
    'expected_count', v_expected,
    'publication_mode', 'average'
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

REVOKE ALL ON FUNCTION public.get_tournament_judging_config(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_tournament_judge_count(uuid, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_manager_judge_tournament_data(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_judge_game_score(uuid, text, integer, uuid, text, text, jsonb, boolean, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.review_judge_game_submission(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.approve_judge_game_results(uuid, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_manager_judge_game_submissions(uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_tournament_judging_config(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_tournament_judge_count(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manager_judge_tournament_data(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_judge_game_score(uuid, text, integer, uuid, text, text, jsonb, boolean, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_judge_game_submission(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_judge_game_results(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manager_judge_game_submissions(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
