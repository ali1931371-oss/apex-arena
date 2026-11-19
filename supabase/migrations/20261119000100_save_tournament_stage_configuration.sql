-- APEX ARENA: persist stage order and group configuration per tournament.
-- Review this migration before running it manually in Supabase SQL Editor.
-- This file is prepared only; it has NOT been executed.

CREATE OR REPLACE FUNCTION public.save_tournament_stage_configuration(
  p_tournament_id uuid,
  p_stages jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_stage jsonb;
  v_existing public.tournament_stages%ROWTYPE;
  v_id uuid;
  v_name text;
  v_position integer := 0;
  v_groups integer;
  v_players integer;
  v_games integer;
  v_saved_ids uuid[] := ARRAY[]::uuid[];
  v_group_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مجاز به ذخیره تنظیمات مراحل تورنمنت است.';
  END IF;

  IF p_tournament_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.tournaments t WHERE t.id = p_tournament_id
  ) THEN
    RAISE EXCEPTION 'تورنمنت انتخاب‌شده پیدا نشد.';
  END IF;

  IF p_stages IS NULL OR jsonb_typeof(p_stages) <> 'array' THEN
    RAISE EXCEPTION 'اطلاعات مراحل باید به‌صورت فهرست ارسال شود.';
  END IF;

  IF jsonb_array_length(p_stages) > 50 THEN
    RAISE EXCEPTION 'هر تورنمنت حداکثر می‌تواند ۵۰ مرحله داشته باشد.';
  END IF;

  -- Free the unique (tournament_id, stage_number) values before applying
  -- the requested order, so moving stages never causes a temporary conflict.
  UPDATE public.tournament_stages
  SET stage_number = stage_number + 1000000
  WHERE tournament_id = p_tournament_id;

  FOR v_stage IN SELECT value FROM jsonb_array_elements(p_stages)
  LOOP
    v_position := v_position + 1;
    v_name := btrim(coalesce(v_stage->>'name', ''));
    v_groups := (v_stage->'settings'->>'groups')::integer;
    v_players := (v_stage->'settings'->>'players')::integer;
    v_games := (v_stage->'settings'->>'games')::integer;

    IF v_name = '' OR length(v_name) > 100 THEN
      RAISE EXCEPTION 'نام هر مرحله باید بین ۱ تا ۱۰۰ نویسه باشد.';
    END IF;
    IF v_groups NOT BETWEEN 1 AND 100
       OR v_players NOT BETWEEN 1 AND 100
       OR v_games NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION 'تعداد گروه، بازیکن و بازی باید بین ۱ تا ۱۰۰ باشد.';
    END IF;

    IF nullif(v_stage->>'id', '') IS NULL THEN
      v_id := gen_random_uuid();
      INSERT INTO public.tournament_stages
        (id, tournament_id, name, stage_number, settings)
      VALUES (
        v_id, p_tournament_id, v_name, v_position,
        jsonb_build_object(
          'groups_count', v_groups,
          'players_per_group', v_players,
          'games_per_group', v_games,
          'configurable', true
        )
      );
    ELSE
      v_id := (v_stage->>'id')::uuid;
      SELECT * INTO v_existing
      FROM public.tournament_stages
      WHERE id = v_id AND tournament_id = p_tournament_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'یکی از مراحل ارسالی متعلق به این تورنمنت نیست.';
      END IF;

      UPDATE public.tournament_stages
      SET name = v_name,
          stage_number = v_position,
          settings = coalesce(settings, '{}'::jsonb) || jsonb_build_object(
            'groups_count', v_groups,
            'players_per_group', v_players,
            'games_per_group', v_games,
            'configurable', true
          )
      WHERE id = v_id AND tournament_id = p_tournament_id;
    END IF;

    v_saved_ids := array_append(v_saved_ids, v_id);

    IF EXISTS (
      SELECT 1 FROM public.matches m
      WHERE m.stage_id = v_id
    ) THEN
      SELECT count(*) INTO v_group_count
      FROM public.tournament_groups g
      WHERE g.stage_id = v_id;

      IF v_group_count <> v_groups THEN
        RAISE EXCEPTION
          'مرحله «%» مسابقه ثبت‌شده دارد؛ برای جلوگیری از به‌هم‌خوردن سوابق، تعداد گروه‌های آن قابل تغییر نیست.',
          v_name;
      END IF;
    ELSE
      DELETE FROM public.tournament_groups
      WHERE stage_id = v_id;

      INSERT INTO public.tournament_groups
        (stage_id, group_number, group_name)
      SELECT v_id, n, 'گروه ' || n
      FROM generate_series(1, v_groups) AS n;
    END IF;
  END LOOP;

  -- Remove stages omitted from the saved order only when they have no matches.
  FOR v_existing IN
    SELECT *
    FROM public.tournament_stages
    WHERE tournament_id = p_tournament_id
  LOOP
    IF NOT (v_existing.id = ANY(v_saved_ids)) THEN
      IF EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.stage_id = v_existing.id
      ) THEN
        RAISE EXCEPTION
          'مرحله «%» مسابقه ثبت‌شده دارد و نمی‌توان آن را از تورنمنت حذف کرد.',
          v_existing.name;
      END IF;

      DELETE FROM public.tournament_groups
      WHERE stage_id = v_existing.id;

      DELETE FROM public.tournament_stages
      WHERE id = v_existing.id
        AND tournament_id = p_tournament_id;
    END IF;
  END LOOP;

  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'stage_number', s.stage_number,
        'settings', s.settings
      ) ORDER BY s.stage_number
    )
    FROM public.tournament_stages s
    WHERE s.tournament_id = p_tournament_id
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.save_tournament_stage_configuration(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_tournament_stage_configuration(uuid, jsonb) TO authenticated;
