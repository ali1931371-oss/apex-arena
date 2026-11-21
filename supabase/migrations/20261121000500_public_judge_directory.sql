-- APEX ARENA: public directory of active tournament judges.
-- Exposes only judge display names and active tournament names; no emails or account IDs.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_public_judge_directory()
RETURNS TABLE (
  judge_name text,
  tournament_id uuid,
  tournament_name text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    COALESCE(NULLIF(btrim(p.display_name), ''), 'داور') AS judge_name,
    tj.tournament_id,
    t.name AS tournament_name
  FROM public.tournament_judges AS tj
  JOIN public.tournaments AS t ON t.id = tj.tournament_id
  JOIN public.profiles AS p ON p.id = tj.judge_id
  WHERE tj.is_active = true
  ORDER BY p.display_name, t.name;
$$;

REVOKE ALL ON FUNCTION public.get_public_judge_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_judge_directory() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
