-- APEX ARENA: create a tournament together with its stages and groups.
-- Prepared for review; do not run until the full script has been reviewed and approved.

CREATE OR REPLACE FUNCTION public.create_managed_tournament_with_stages(
  p_name text,
  p_max_players integer,
  p_registration_open boolean,
  p_require_admin_approval boolean,
  p_stages jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tournament_id uuid := gen_random_uuid();
  v_stage jsonb;
  v_name text := btrim(coalesce(p_name, ''));
  v_slug text := 'tournament-' || replace(v_tournament_id::text, '-', '');
  v_stage_name text;
  v_stage_number integer := 0;
  v_groups integer;
  v_players integer;
  v_games integer;
  v_stage_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_apex_manager() THEN
    RAISE EXCEPTION 'فقط مدیر یا مسئول مسابقه مجاز به ساخت تورنمنت است.';
  END IF;

  IF v_name = '' OR length(v_name) > 120 THEN
    RAISE EXCEPTION 'نام تورنمنت باید بین ۱ تا ۱۲۰ نویسه باشد.';
  END IF;

  IF p_max_players IS NULL OR p_max_players NOT BETWEEN 2 AND 500 THEN
    RAISE EXCEPTION 'ظرفیت تورنمنت باید عددی بین ۲ تا ۵۰۰ باشد.';
  END IF;

  IF p_registration_open IS NULL OR p_require_admin_approval IS NULL THEN
    RAISE EXCEPTION 'وضعیت ثبت‌نام و تأیید مدیر باید مشخص باشد.';
  END IF;

  IF p_stages IS NULL OR jsonb_typeof(p_stages) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_stages) < 1
     OR jsonb_array_length(p_stages) > 50 THEN
    RAISE EXCEPTION 'حداقل یک و حداکثر ۵۰ مرحله باید برای تورنمنت تعیین شود.';
  END IF;

  INSERT INTO public.tournaments (id, name, slug, created_by)
  VALUES (v_tournament_id, v_name, v_slug, auth.uid());

  INSERT INTO public.tournament_registration_settings (
    tournament_id, max_players, registration_open, require_admin_approval
  )
  VALUES (
    v_tournament_id, p_max_players, p_registration_open, p_require_admin_approval
  );

  FOR v_stage IN SELECT value FROM jsonb_array_elements(p_stages)
  LOOP
    v_stage_number := v_stage_number + 1;
    IF jsonb_typeof(v_stage) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'ساختار یکی از مراحل معتبر نیست.';
    END IF;

    v_stage_name := btrim(coalesce(v_stage->>'name', ''));
    v_groups := nullif(v_stage->'settings'->>'groups', '')::integer;
    v_players := nullif(v_stage->'settings'->>'players', '')::integer;
    v_games := nullif(v_stage->'settings'->>'games', '')::integer;

    IF v_stage_name = '' OR length(v_stage_name) > 100 THEN
      RAISE EXCEPTION 'نام هر مرحله باید بین ۱ تا ۱۰۰ نویسه باشد.';
    END IF;

    IF v_groups IS NULL OR v_groups NOT BETWEEN 1 AND 100
       OR v_players IS NULL OR v_players NOT BETWEEN 1 AND 100
       OR v_games IS NULL OR v_games NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION 'تعداد گروه، بازیکن و بازی هر مرحله باید بین ۱ تا ۱۰۰ باشد.';
    END IF;

    v_stage_id := gen_random_uuid();
    INSERT INTO public.tournament_stages (id, tournament_id, name, stage_number, settings)
    VALUES (
      v_stage_id,
      v_tournament_id,
      v_stage_name,
      v_stage_number,
      jsonb_build_object(
        'groups_count', v_groups,
        'players_per_group', v_players,
        'games_per_group', v_games,
        'configurable', true
      )
    );

    INSERT INTO public.tournament_groups (stage_id, group_number, group_name)
    SELECT v_stage_id, n, 'گروه ' || n
    FROM generate_series(1, v_groups) AS n;
  END LOOP;

  RETURN v_tournament_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_managed_tournament_with_stages(text, integer, boolean, boolean, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_managed_tournament_with_stages(text, integer, boolean, boolean, jsonb) TO authenticated;
