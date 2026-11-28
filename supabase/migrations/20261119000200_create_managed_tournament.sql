-- APEX ARENA: create a tournament and its registration settings atomically.
-- Review this migration before running it manually in Supabase SQL Editor.
-- This migration is prepared only; it has NOT been executed.

CREATE OR REPLACE FUNCTION public.create_managed_tournament(
  p_name text,
  p_max_players integer,
  p_registration_open boolean,
  p_require_admin_approval boolean
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tournament_id uuid := gen_random_uuid();
  v_name text := btrim(coalesce(p_name, ''));
  v_slug text := 'tournament-' || replace(v_tournament_id::text, '-', '');
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

  INSERT INTO public.tournaments (
    id,
    name,
    slug,
    created_by
  )
  VALUES (
    v_tournament_id,
    v_name,
    v_slug,
    auth.uid()
  );

  INSERT INTO public.tournament_registration_settings (
    tournament_id,
    max_players,
    registration_open,
    require_admin_approval
  )
  VALUES (
    v_tournament_id,
    p_max_players,
    p_registration_open,
    p_require_admin_approval
  );

  RETURN v_tournament_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_managed_tournament(text, integer, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_managed_tournament(text, integer, boolean, boolean) TO authenticated;
